#!/usr/bin/env python3
"""
PiAuditor BLE GATT Daemon
Autonomous Out-of-Band Bluetooth Low Energy Control Server for Raspberry Pi 3B+
Enables zero-Wi-Fi iOS control when wlan0 is locked in monitor mode (wlan0mon).
"""

import sys
import os
import json
import time
import subprocess
import threading
import signal
import urllib.request

try:
    import dbus
    import dbus.service
    import dbus.mainloop.glib
    from gi.repository import GLib
except ImportError:
    print("[!] Error: python3-dbus and python3-gi required. Install via: apt install python3-dbus python3-gi")
    sys.exit(1)

# Bluetooth LE UUIDs
BLUEZ_SERVICE_NAME = 'org.bluez'
GATT_MANAGER_IFACE = 'org.bluez.GattManager1'
DBUS_OM_IFACE = 'org.freedesktop.DBus.ObjectManager'
DBUS_PROP_IFACE = 'org.freedesktop.DBus.Properties'
GATT_SERVICE_IFACE = 'org.bluez.GattService1'
GATT_CHRC_IFACE = 'org.bluez.GattCharacteristic1'
GATT_DESC_IFACE = 'org.bluez.GattDescriptor1'
LE_ADVERTISING_MANAGER_IFACE = 'org.bluez.LEAdvertisingManager1'
LE_ADVERTISEMENT_IFACE = 'org.bluez.LEAdvertisement1'

SERVICE_UUID = '0000a001-0000-1000-8000-00805f9b34fb'
STATUS_CHRC_UUID = '0000a002-0000-1000-8000-00805f9b34fb'
COMMAND_CHRC_UUID = '0000a003-0000-1000-8000-00805f9b34fb'
SURVEY_CHRC_UUID = '0000a004-0000-1000-8000-00805f9b34fb'


class InvalidArgsException(dbus.exceptions.DBusException):
    _dbus_error_name = 'org.bluez.Error.InvalidArguments'


class NotSupportedException(dbus.exceptions.DBusException):
    _dbus_error_name = 'org.bluez.Error.NotSupported'


class Application(dbus.service.Object):
    def __init__(self, bus):
        self.path = '/'
        self.services = []
        super().__init__(bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_service(self, service):
        self.services.append(service)

    @dbus.service.method(DBUS_OM_IFACE, out_signature='a{oa{sa{sv}}}')
    def GetManagedObjects(self):
        response = {}
        for service in self.services:
            response[service.get_path()] = service.get_properties()
            chrcs = service.get_characteristics()
            for chrc in chrcs:
                response[chrc.get_path()] = chrc.get_properties()
        return response


class Service(dbus.service.Object):
    PATH_BASE = '/org/bluez/example/service'

    def __init__(self, bus, index, uuid, primary):
        self.path = self.PATH_BASE + str(index)
        self.bus = bus
        self.uuid = uuid
        self.primary = primary
        self.characteristics = []
        super().__init__(bus, self.path)

    def get_properties(self):
        return {
            GATT_SERVICE_IFACE: {
                'UUID': self.uuid,
                'Primary': self.primary,
                'Characteristics': dbus.Array(
                    [c.get_path() for c in self.characteristics],
                    signature='o')
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_characteristic(self, characteristic):
        self.characteristics.append(characteristic)

    def get_characteristics(self):
        return self.characteristics


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service):
        self.path = service.path + '/char' + str(index)
        self.bus = bus
        self.uuid = uuid
        self.service = service
        self.flags = flags
        self.descriptors = []
        super().__init__(bus, self.path)

    def get_properties(self):
        return {
            GATT_CHRC_IFACE: {
                'Service': self.service.get_path(),
                'UUID': self.uuid,
                'Flags': self.flags,
                'Descriptors': dbus.Array(
                    [d.get_path() for d in self.descriptors],
                    signature='o')
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)


class StatusCharacteristic(Characteristic):
    def __init__(self, bus, index, service, daemon_state):
        super().__init__(bus, index, STATUS_CHRC_UUID, ['read', 'notify'], service)
        self.notifying = False
        self.state = daemon_state

    def send_status_notification(self):
        if not self.notifying:
            return
        payload = json.dumps(self.state.get_status()).encode('utf-8')
        value = [dbus.Byte(b) for b in payload]
        self.PropertiesChanged(
            GATT_CHRC_IFACE,
            {'Value': value},
            []
        )

    @dbus.service.signal(DBUS_PROP_IFACE, signature='sa{sv}as')
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    @dbus.service.method(GATT_CHRC_IFACE, in_signature='a{sv}', out_signature='ay')
    def ReadValue(self, options):
        offset = int(options.get('offset', 0))
        payload = json.dumps(self.state.get_status()).encode('utf-8')
        if offset > len(payload):
            return []
        return [dbus.Byte(b) for b in payload[offset:]]

    @dbus.service.method(GATT_CHRC_IFACE)
    def StartNotify(self):
        if self.notifying:
            return
        self.notifying = True
        print("[+] iOS client subscribed to Status notifications.")

    @dbus.service.method(GATT_CHRC_IFACE)
    def StopNotify(self):
        self.notifying = False
        print("[-] iOS client unsubscribed from Status notifications.")


class CommandCharacteristic(Characteristic):
    def __init__(self, bus, index, service, daemon_state, status_chrc):
        super().__init__(bus, index, COMMAND_CHRC_UUID, ['write', 'write-without-response'], service)
        self.state = daemon_state
        self.status_chrc = status_chrc

    @dbus.service.method(GATT_CHRC_IFACE, in_signature='aya{sv}')
    def WriteValue(self, value, options):
        cmd_str = bytes(value).decode('utf-8', errors='replace')
        print(f"[CMD INCOMING]: {cmd_str}")
        try:
            cmd_json = json.loads(cmd_str)
            self.state.execute_command(cmd_json)
            self.status_chrc.send_status_notification()
        except Exception as e:
            print(f"[!] Error processing command: {e}")


class SurveyCharacteristic(Characteristic):
    def __init__(self, bus, index, service, daemon_state):
        super().__init__(bus, index, SURVEY_CHRC_UUID, ['read', 'notify'], service)
        self.notifying = False
        self.state = daemon_state

    @dbus.service.method(GATT_CHRC_IFACE, in_signature='a{sv}', out_signature='ay')
    def ReadValue(self, options):
        offset = int(options.get('offset', 0))
        survey_data = json.dumps(self.state.get_survey()).encode('utf-8')
        if offset > len(survey_data):
            return []
        return [dbus.Byte(b) for b in survey_data[offset:]]

    @dbus.service.method(GATT_CHRC_IFACE)
    def StartNotify(self):
        self.notifying = True

    @dbus.service.method(GATT_CHRC_IFACE)
    def StopNotify(self):
        self.notifying = False


class Advertisement(dbus.service.Object):
    PATH_BASE = '/org/bluez/example/advertisement'

    def __init__(self, bus, index, advertising_type):
        self.path = self.PATH_BASE + str(index)
        self.bus = bus
        self.ad_type = advertising_type
        self.service_uuids = [SERVICE_UUID]
        self.local_name = 'PiAuditor-BLE'
        self.include_tx_power = True
        super().__init__(bus, self.path)

    def get_properties(self):
        properties = dict()
        properties['Type'] = self.ad_type
        properties['ServiceUUIDs'] = dbus.Array(self.service_uuids, signature='s')
        properties['LocalName'] = dbus.String(self.local_name)
        properties['IncludeTxPower'] = dbus.Boolean(self.include_tx_power)
        return {LE_ADVERTISEMENT_IFACE: properties}

    def get_path(self):
        return dbus.ObjectPath(self.path)

    @dbus.service.method(DBUS_PROP_IFACE, in_signature='s', out_signature='a{sv}')
    def GetAll(self, interface):
        if interface != LE_ADVERTISEMENT_IFACE:
            raise InvalidArgsException()
        return self.get_properties()[LE_ADVERTISEMENT_IFACE]

    @dbus.service.method(LE_ADVERTISEMENT_IFACE, in_signature='', out_signature='')
    def Release(self):
        print(f"[-] Advertisement {self.path} released")


class DaemonState:
    def __init__(self):
        self.mode = "STANDBY"
        self.target_ssid = ""
        self.target_bssid = ""
        self.channel = 0
        self.handshakes_count = 0
        self.active_clients = 0
        self.last_event = "System Initialized"
        self.survey_cache = []

    def get_cpu_temp(self):
        try:
            with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
                return round(float(f.read().strip()) / 1000.0, 1)
        except Exception:
            return 0.0

    def get_status(self):
        mode = "STANDBY"
        target_ssid = self.target_ssid
        target_bssid = self.target_bssid
        channel = self.channel
        handshakes = self.handshakes_count
        clients = self.active_clients
        last_event = self.last_event

        try:
            req = urllib.request.Request("http://127.0.0.1:5000/api/status", headers={"User-Agent": "PiAuditor-BLE"})
            with urllib.request.urlopen(req, timeout=1.0) as resp:
                data = json.loads(resp.read().decode())
                mode = data.get("mode", "STANDBY")
                tgt = data.get("target") or {}
                if tgt:
                    target_ssid = tgt.get("ssid", target_ssid)
                    target_bssid = tgt.get("bssid", target_bssid)
                    channel = tgt.get("channel", channel)
                if data.get("handshake_captured"):
                    handshakes = 1
                phase = data.get("burst_phase", "")
                if phase:
                    last_event = f"{mode}: {phase}"
        except Exception:
            job_file = "/home/khoa/wifi_auditor/current_job.json"
            if os.path.exists(job_file):
                try:
                    with open(job_file, "r") as f:
                        j = json.load(f)
                        target_ssid = j.get("ssid", target_ssid)
                        target_bssid = j.get("bssid", target_bssid)
                        channel = j.get("channel", channel)
                        mode = "AUDITING"
                        if j.get("handshake_captured"):
                            handshakes = 1
                except Exception:
                    pass

        return {
            "mode": mode,
            "target_ssid": target_ssid,
            "target_bssid": target_bssid,
            "channel": channel,
            "handshakes": handshakes,
            "clients": clients,
            "cpu_temp": self.get_cpu_temp(),
            "event": last_event,
            "uptime": int(time.time())
        }

    def get_survey(self):
        survey_file = "/home/khoa/wifi_auditor/survey.json"
        if os.path.exists(survey_file):
            try:
                with open(survey_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    sorted_data = sorted(data, key=lambda x: x.get('rssi', -100), reverse=True)
                    nets = []
                    for item in sorted_data[:15]:
                        nets.append({
                            "ssid": item.get("ssid", "Unknown")[:24],
                            "bssid": item.get("bssid", ""),
                            "channel": item.get("channel", 1),
                            "signal": item.get("rssi", -80),
                            "security": item.get("crypto", "WPA2")
                        })
                    return nets
            except Exception:
                pass
        return self.survey_cache

    def execute_command(self, cmd):
        action = cmd.get("action", "").upper()
        if action == "START_AUDIT":
            self.target_ssid = cmd.get("ssid", "")
            self.target_bssid = cmd.get("bssid", "")
            self.channel = int(cmd.get("channel", 1))
            self.mode = "AUDITING"
            self.last_event = f"Audit started for {self.target_ssid} (ch {self.channel})"

            def _post_start():
                try:
                    payload = json.dumps({
                        "ssid": self.target_ssid,
                        "bssid": self.target_bssid,
                        "channel": self.channel,
                        "bursts": 3
                    }).encode("utf-8")
                    req = urllib.request.Request(
                        "http://127.0.0.1:5000/api/start",
                        data=payload,
                        headers={"Content-Type": "application/json"}
                    )
                    urllib.request.urlopen(req, timeout=3.0)
                except Exception as e:
                    self.last_event = f"Start API error: {e}"
            threading.Thread(target=_post_start, daemon=True).start()

        elif action == "STOP_AUDIT":
            self.mode = "STANDBY"
            self.last_event = "Audit aborted by operator"
            def _post_abort():
                try:
                    req = urllib.request.Request("http://127.0.0.1:5000/api/abort", data=b"{}")
                    urllib.request.urlopen(req, timeout=3.0)
                except Exception:
                    pass
            threading.Thread(target=_post_abort, daemon=True).start()

        elif action == "SURVEY":
            self.last_event = "Triggering Wi-Fi environment survey"
            def _post_rescan():
                try:
                    req = urllib.request.Request("http://127.0.0.1:5000/api/rescan", data=b"{}")
                    urllib.request.urlopen(req, timeout=3.0)
                except Exception:
                    pass
            threading.Thread(target=_post_rescan, daemon=True).start()

        elif action == "REBOOT":
            self.last_event = "Rebooting system..."
            threading.Thread(target=lambda: (time.sleep(2), subprocess.run(["reboot"]))).start()

        elif action == "SHUTDOWN":
            self.last_event = "Shutting down..."
            threading.Thread(target=lambda: (time.sleep(2), subprocess.run(["poweroff"]))).start()


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    # Find Bluetooth adapter
    manager = dbus.Interface(bus.get_object(BLUEZ_SERVICE_NAME, '/'), DBUS_OM_IFACE)
    objects = manager.GetManagedObjects()

    adapter_path = None
    for path, interfaces in objects.items():
        if 'org.bluez.Adapter1' in interfaces:
            adapter_path = path
            break

    if not adapter_path:
        print("[!] No Bluetooth adapter found on system!")
        sys.exit(1)

    adapter_props = dbus.Interface(bus.get_object(BLUEZ_SERVICE_NAME, adapter_path), DBUS_PROP_IFACE)
    adapter_props.Set('org.bluez.Adapter1', 'Powered', dbus.Boolean(True))
    adapter_props.Set('org.bluez.Adapter1', 'Discoverable', dbus.Boolean(True))
    adapter_props.Set('org.bluez.Adapter1', 'Alias', dbus.String('PiAuditor-BLE'))

    daemon_state = DaemonState()

    # GATT Application
    app = Application(bus)
    service = Service(bus, 0, SERVICE_UUID, True)
    status_chrc = StatusCharacteristic(bus, 0, service, daemon_state)
    cmd_chrc = CommandCharacteristic(bus, 1, service, daemon_state, status_chrc)
    survey_chrc = SurveyCharacteristic(bus, 2, service, daemon_state)

    service.add_characteristic(status_chrc)
    service.add_characteristic(cmd_chrc)
    service.add_characteristic(survey_chrc)
    app.add_service(service)

    # Register GATT Application
    service_manager = dbus.Interface(bus.get_object(BLUEZ_SERVICE_NAME, adapter_path), GATT_MANAGER_IFACE)
    service_manager.RegisterApplication(app.get_path(), {},
        reply_handler=lambda: print("[+] GATT Application successfully registered!"),
        error_handler=lambda err: print(f"[!] Failed to register GATT Application: {err}"))

    # Register LE Advertisement
    ad_manager = dbus.Interface(bus.get_object(BLUEZ_SERVICE_NAME, adapter_path), LE_ADVERTISING_MANAGER_IFACE)
    ad = Advertisement(bus, 0, 'peripheral')
    ad_manager.RegisterAdvertisement(ad.get_path(), {},
        reply_handler=lambda: print("[+] LE Advertisement active (PiAuditor-BLE)"),
        error_handler=lambda err: print(f"[!] Failed to register LE Advertisement: {err}"))

    # Periodic Status Notifier (every 3 seconds)
    def periodic_update():
        status_chrc.send_status_notification()
        return True

    GLib.timeout_add_seconds(3, periodic_update)

    print("[*] PiAuditor BLE Daemon running. Listening for iOS connections...")
    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        print("\n[*] Stopping BLE Daemon...")


if __name__ == '__main__':
    main()
