import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import 'dart:convert';

void main() {
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: AttendanceCheckScreen(),
  ));
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

  Future<void> initDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      setState(() {
        deviceId = androidInfo.id ?? "UNKNOWN_ANDROID_ID";
      });
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      setState(() {
        deviceId = iosInfo.identifierForVendor ?? "UNKNOWN_IOS_ID";
      });
    }
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

    double distanceInMeters = Geolocator.distanceBetween(
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
      // Sort times to get correct IN (earliest) and OUT (latest)
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Geo-Fence Attendance")),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
