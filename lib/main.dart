import 'package:flutter/material.dart';

void main() {
  runApp(const MedTrackApp());
}

class MedTrackApp extends StatelessWidget {
  const MedTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MedTrack',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const InventoryHomePage(),
    );
  }
}

class InventoryHomePage extends StatefulWidget {
  const InventoryHomePage({super.key});

  @override
  State<InventoryHomePage> createState() => _InventoryHomePageState();
}

class _InventoryHomePageState extends State<InventoryHomePage> {
  // الذاكرة المؤقتة للأصناف، أصبحت تستقبل أرقاماً وتواريخ للقيام بالعمليات الحسابية
  final List<Map<String, dynamic>> _inventoryItems = [];

  // أجهزة الاستشعار للخانات الخمس
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _stockAlertController = TextEditingController();
  final TextEditingController _expiryController = TextEditingController();
  final TextEditingController _expiryAlertController = TextEditingController();

  void _addNewItem() {
    if (_nameController.text.isEmpty || _quantityController.text.isEmpty) {
      return;
    }

    setState(() {
      _inventoryItems.add({
        'name': _nameController.text,
        'quantity': int.tryParse(_quantityController.text) ?? 0,
        'stockAlert': int.tryParse(_stockAlertController.text) ?? 0,
        'expiryDate': _expiryController.text.isEmpty ? 'Not Set' : _expiryController.text,
        'expiryAlertMonths': int.tryParse(_expiryAlertController.text) ?? 0,
      });
    });

    _nameController.clear();
    _quantityController.clear();
    _stockAlertController.clear();
    _expiryController.clear();
    _expiryAlertController.clear();

    Navigator.pop(context);
  }

  // دالة حسابية لمعرفة ما إذا كان الدواء قريباً من الانتهاء بناءً على الشرط المخصص
  bool _isNearExpiry(String dateStr, int alertMonths) {
    if (dateStr == 'Not Set' || alertMonths == 0) return false;
    DateTime? expDate = DateTime.tryParse(dateStr);
    if (expDate == null) return false;

    final now = DateTime.now();
    final differenceInDays = expDate.difference(now).inDays;
    // نعتبر الشهر 30 يوماً للتبسيط الحسابي
    return differenceInDays <= (alertMonths * 30);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text(
          'MedTrack - OR Vault',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _inventoryItems.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.inventory_2_outlined, size: 100, color: Colors.teal),
                  SizedBox(height: 20),
                  Text(
                    'Welcome to OR Vault',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 10),
                  Text('Press (+) to add a new item'),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _inventoryItems.length,
              itemBuilder: (context, index) {
                final item = _inventoryItems[index];
                
                // استخراج المتغيرات من الذاكرة
                final int qty = item['quantity'];
                final int stockAlert = item['stockAlert'];
                final String expiryDateStr = item['expiryDate'];
                final int expiryAlertMonths = item['expiryAlertMonths'];

                // فحص الشروط المنطقية للإشعارات
                final bool isLowStock = qty <= stockAlert;
                final bool isNearExpiry = _isNearExpiry(expiryDateStr, expiryAlertMonths);

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  elevation: 2,
                  // تلوين إطار البطاقة بالأحمر إذا كان هناك تحذير
                  shape: RoundedRectangleBorder(
                    side: BorderSide(
                      color: (isLowStock || isNearExpiry) ? Colors.red.shade300 : Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: (isLowStock || isNearExpiry) ? Colors.red : Colors.teal,
                      child: Icon(
                        (isLowStock || isNearExpiry) ? Icons.warning_amber_rounded : Icons.medical_services,
                        color: Colors.white,
                      ),
                    ),
                    title: Text(
                      item['name'],
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text('Expiry: $expiryDateStr'),
                        // إظهار نصوص التحذير في حال تحقق الشروط
                        if (isNearExpiry)
                          const Text('⚠️ Expiring Soon!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                        if (isLowStock)
                          const Text('⚠️ Low Stock Alert!', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isLowStock ? Colors.red.shade50 : Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Qty: $qty',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isLowStock ? Colors.red : Colors.teal,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            builder: (context) {
              return Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  left: 16,
                  right: 16,
                  top: 24,
                ),
                // إضافة قابلية التمرير (Scrolling) للنافذة لتتسع للخانات الجديدة
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Add New Item',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Item Name (e.g., Propofol)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _quantityController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Current Qty',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _stockAlertController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Alert at Qty',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _expiryController,
                        decoration: const InputDecoration(
                          labelText: 'Expiry Date (YYYY-MM-DD)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _expiryAlertController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Alert Before Expiry (Months)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                        ),
                        onPressed: _addNewItem,
                        child: const Text('Save to Vault', style: TextStyle(fontSize: 18)),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              );
            },
          );
        },
        tooltip: 'Add Item',
        child: const Icon(Icons.add),
      ),
    );
  }
}
