/// A corner of a layout: where its apex (slowest point) is, numbered in
/// lap order from the line (C1, C2, ...). GT7 has no corner data, so
/// these are found from the driver's own reference lap (see
/// CornerDetector) and saved with the layout's sector lines.
class Corner {
  final int number;
  final double x, z;

  const Corner({required this.number, required this.x, required this.z});

  factory Corner.fromMap(Map<String, dynamic> m) =>
      Corner(number: (m['number'] as num).toInt(), x: (m['x'] as num).toDouble(), z: (m['z'] as num).toDouble());

  Map<String, dynamic> toMap() => {'number': number, 'x': x, 'z': z};
}
