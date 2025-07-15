import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: AttendanceCheckScreen(),
  ));
}
class MyLinkWidget extends StatelessWidget {
  final Uri _url = Uri.parse('http://10.250.10.100/mucc/frontend/web/index.php?r=attendance/report');

  Future<void> _launchUrl() async {
    if (!await launchUrl(_url)) {
      throw Exception('Could not launch $_url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: _launchUrl,
      child: Text('Open Google'),
    );
  }
}
class AttendanceCheckScreen extends StatefulWidget {
  @override
  _AttendanceCheckScreenState createState() => _AttendanceCheckScreenState();
}


class _AttendanceCheckScreenState extends State<AttendanceCheckScreen> {
  bool isEligible = false;
  String statusMessage = "Checking conditions...";

  final double targetLat = 24.7520393;
  final double targetLng = 93.9322356;
  Position? currentPosition;
  String? wifiSSID;
  String? wifiBSSID;
  String deviceId = "";
  double distanceInMeters = 0;

  bool locationOn = false;
  bool wifiConnected = false;
  bool withinGeofence = false;

  Map<String, List<String>> attendanceMap = {}; // {'09-07-2025': ['10:00 AM', '05:00 PM']}

  @override
  void initState() {
    super.initState();
    initDeviceId();
    checkAllConditions();
  }

  Future<String> generateAndStoreDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? cachedId = prefs.getString('device_id');
    if (cachedId != null && cachedId.isNotEmpty) {
      return cachedId;
    }

    final deviceInfo = DeviceInfoPlugin();
    String raw = "";

    try {
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        raw = "${info.manufacturer}_${info.model}_${info.id}";
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        raw = "${info.name}_${info.model}_${info.identifierForVendor ?? ''}";
      } else if (Platform.isWindows) {
        final info = await deviceInfo.windowsInfo;
        raw = "${info.computerName}_${info.deviceId}";
      } else if (Platform.isLinux) {
        final info = await deviceInfo.linuxInfo;
        raw = "${info.name}_${info.machineId}";
      } else if (Platform.isMacOS) {
        final info = await deviceInfo.macOsInfo;
        raw = "${info.computerName}_${info.systemGUID ?? ''}";
      }
    } catch (e) {
      print("Device ID error: $e");
      raw = DateTime.now().millisecondsSinceEpoch.toString();
    }

    String shortId = sha1.convert(utf8.encode(raw)).toString().substring(0, 8);
    await prefs.setString('device_id', shortId);
    return shortId;
  }

  Future<void> initDeviceId() async {
    deviceId = await generateAndStoreDeviceId();
    fetchAttendanceLogs();
  }

  Future<void> checkAllConditions() async {
    setState(() {
      statusMessage = "Checking location and WiFi...";
    });

    await Permission.location.request();
    await Permission.locationAlways.request();

    bool locationServiceEnabled = await Geolocator.isLocationServiceEnabled();
    locationOn = locationServiceEnabled;
    if (!locationOn) {
      await Geolocator.openLocationSettings();
      updateUI();
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) {
        updateUI();
        return;
      }
    }

    try {
      currentPosition = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    } catch (e) {
      updateUI();
      return;
    }

    distanceInMeters = Geolocator.distanceBetween(
      currentPosition!.latitude,
      currentPosition!.longitude,
      targetLat,
      targetLng,
    );
    withinGeofence = distanceInMeters <= 200;

    final info = NetworkInfo();
    wifiSSID = await info.getWifiName();
    wifiBSSID = await info.getWifiBSSID();
    wifiConnected = wifiSSID != null && wifiBSSID != null && wifiSSID!.isNotEmpty && wifiBSSID!.isNotEmpty;

    updateUI();
  }

  void updateUI() {
    isEligible = locationOn && wifiConnected && withinGeofence;
    setState(() {
      if (isEligible) {
        statusMessage = "All conditions satisfied ✅";
      } else {
        statusMessage = "One or more conditions not met ❌";
      }
    });
  }

  Future<void> submitAttendance() async {
    final now = DateTime.now();
    final formatted = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);

    final url = Uri.parse("http://10.250.10.100/atten/receive_attendance.php");
    final response = await http.post(url, body: {
      'device_id': deviceId,
      'latitude': currentPosition!.latitude.toString(),
      'longitude': currentPosition!.longitude.toString(),
      'dis_gfence': '1',
      'wifi_mac': wifiBSSID ?? '',
      'wifissid': wifiSSID ?? '',
      'timestamp': formatted
    });

    if (response.statusCode == 200) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Attendance Submitted ✅")),
      );
      fetchAttendanceLogs();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to submit attendance ❌")),
      );
    }
  }

  Future<void> fetchAttendanceLogs() async {
    final url = Uri.parse("http://10.250.10.100/atten/read_attendance.php?device_id=$deviceId");
    final response = await http.get(url);

    if (response.statusCode == 200) {
      List<dynamic> logs = jsonDecode(response.body);
      Map<String, List<String>> map = {};
      for (var entry in logs) {
        DateTime ts = DateTime.parse(entry['timestamp']);
        String date = DateFormat('dd-MM-yyyy').format(ts);
        String time = DateFormat('hh:mm a').format(ts);
        map.putIfAbsent(date, () => []);
        map[date]!.add(time);
      }
      for (var date in map.keys) {
        map[date]!.sort((a, b) => DateFormat('hh:mm a').parse(a).compareTo(DateFormat('hh:mm a').parse(b)));
      }
      setState(() {
        attendanceMap = map;
      });
    }
  }

  Future<void> _onRefresh() async {
    await checkAllConditions();
    await fetchAttendanceLogs();
  }

  void _launchMuccWebsite() async {
    final Uri url = Uri.parse('http://10.250.10.100/mucc/frontend/web/index.php?r=attendance/report');
    if (!await launchUrl(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not launch website')),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("MUCC-Geo-Fence Attendance"),
            Image.asset('assets/mu_logo.png', height: 36)
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        child: SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              children: [
                Text(statusMessage, style: TextStyle(fontSize: 18)),
                SizedBox(height: 10),
                Text("Device ID: $deviceId", style: TextStyle(fontSize: 14, color: Colors.grey)),
                if (wifiSSID != null) Text("WiFi SSID: $wifiSSID", style: TextStyle(fontSize: 14, color: Colors.grey)),
                if (currentPosition != null) Text("Distance: ${distanceInMeters.toStringAsFixed(2)} meters", style: TextStyle(fontSize: 14, color: Colors.grey)),
                SizedBox(height: 20),
                ListTile(
                  leading: Icon(locationOn ? Icons.check_circle : Icons.cancel, color: locationOn ? Colors.green : Colors.red),
                  title: Text("Location On"),
                ),
                ListTile(
                  leading: Icon(wifiConnected ? Icons.check_circle : Icons.cancel, color: wifiConnected ? Colors.green : Colors.red),
                  title: Text("WiFi Connected"),
                ),
                ListTile(
                  leading: Icon(withinGeofence ? Icons.check_circle : Icons.cancel, color: withinGeofence ? Colors.green : Colors.red),
                  title: Text("Within Geo-Fence (200m)"),
                ),
                SizedBox(height: 20),



                GestureDetector(
                  onTap: _launchMuccWebsite,
                  child: Text(
                    "View Attendance",
                    style: TextStyle(
                      color: Colors.blue,
                      decoration: TextDecoration.underline,
                      fontSize: 14,
                    ),
                  ),
                ),

                SizedBox(height: 30),

                ElevatedButton(
                  onPressed: isEligible ? submitAttendance : null,
                  child: Text("Submit Attendance"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isEligible ? Colors.green : Colors.grey,
                    padding: EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                  ),
                ),
                SizedBox(height: 20),
                OutlinedButton(
                  onPressed: checkAllConditions,
                  child: Text("Re-check Conditions"),
                ),
                SizedBox(height: 30),
                Divider(),
                Text("Last 7 Days Attendance", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                SizedBox(height: 10),
                ...attendanceMap.entries.map((entry) {
                  String inTime = entry.value.first;
                  String outTime = entry.value.length > 1 ? entry.value.last : "-";
                  return ListTile(
                    title: Text("${entry.key}"),
                    subtitle: Text("IN: $inTime    OUT: $outTime"),
                    leading: Icon(Icons.calendar_today, color: Colors.blue),
                  );
                }).toList(),



                SizedBox(height: 30),
                Text("Designed and Developed by Computer Centre, Manipur University", textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
