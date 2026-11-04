import 'package:hive/hive.dart';

class Transaction {
  final String id;
  final String type;
  final double amount;
  final String description;
  final String? stockItemId;
  final int quantity;
  final DateTime date;
  final double? balance;
  final double? fee;
  final double? fulizaBalance;
  final String? category;
  final String? sourceTransactionId;
  final String? counterpartyName;
  final String? counterpartyPhone;
  final String? jumbeId;
  final String? imagePath;

  Transaction({
    required this.id,
    required this.type,
    required this.amount,
    this.quantity = 1,
    required this.description,
    this.stockItemId,
    required this.date,
    this.balance,
    this.fee,
    this.fulizaBalance,
    this.category,
    this.sourceTransactionId,
    this.counterpartyName,
    this.counterpartyPhone,
    this.jumbeId,
    this.imagePath,
  });
}

class StockItem {
  final String id;
  final String name;
  final int quantity;
  final int initialQuantity;
  final double buyingPrice;
  final double sellingPrice;
  final String mode;
  final int? lowStockLimit;
  final double? expectedTotalSales;
  final double? totalBuyingCost;
  final DateTime dateAdded;

  StockItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.initialQuantity,
    required this.buyingPrice,
    required this.sellingPrice,
    this.mode = 'countable',
    this.lowStockLimit,
    this.expectedTotalSales,
    this.totalBuyingCost,
    required this.dateAdded,
  });
}

class AppSettings {
  String language;
  String currency;
  bool darkMode;

  AppSettings({
    this.language = 'en',
    this.currency = 'KSH',
    this.darkMode = false,
  });
}

class TransactionAdapter extends TypeAdapter<Transaction> {
  static const int typeIdValue = 1;

  @override
  final int typeId = typeIdValue;

  @override
  Transaction read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }

    return Transaction(
      id: fields[0] as String,
      type: fields[1] as String,
      amount: fields[2] as double,
      description: fields[3] as String,
      stockItemId: fields[4] as String?,
      quantity: fields[5] as int,
      date: fields[6] as DateTime,
      balance: fields[7] as double?,
      category: fields[8] as String?,
      sourceTransactionId: fields[9] as String?,
      fee: fields[10] as double?,
      fulizaBalance: fields[11] as double?,
      counterpartyName: fields[12] as String?,
      counterpartyPhone: fields[13] as String?,
      jumbeId: fields[14] as String?,
      imagePath: fields[15] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Transaction obj) {
    writer
      ..writeByte(16)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.type)
      ..writeByte(2)
      ..write(obj.amount)
      ..writeByte(3)
      ..write(obj.description)
      ..writeByte(4)
      ..write(obj.stockItemId)
      ..writeByte(5)
      ..write(obj.quantity)
      ..writeByte(6)
      ..write(obj.date)
      ..writeByte(7)
      ..write(obj.balance)
      ..writeByte(8)
      ..write(obj.category)
      ..writeByte(9)
      ..write(obj.sourceTransactionId)
      ..writeByte(10)
      ..write(obj.fee)
      ..writeByte(11)
      ..write(obj.fulizaBalance)
      ..writeByte(12)
      ..write(obj.counterpartyName)
      ..writeByte(13)
      ..write(obj.counterpartyPhone)
      ..writeByte(14)
      ..write(obj.jumbeId)
      ..writeByte(15)
      ..write(obj.imagePath);
  }
}

class StockItemAdapter extends TypeAdapter<StockItem> {
  static const int typeIdValue = 2;

  @override
  final int typeId = typeIdValue;

  @override
  StockItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }

    return StockItem(
      id: fields[0] as String,
      name: fields[1] as String,
      quantity: fields[2] as int,
      initialQuantity: fields[3] as int,
      buyingPrice: fields[4] as double,
      sellingPrice: fields[5] as double,
      mode: fields[6] as String,
      lowStockLimit: fields[7] as int?,
      expectedTotalSales: fields[8] as double?,
      totalBuyingCost: fields[9] as double?,
      dateAdded: fields[10] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, StockItem obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.quantity)
      ..writeByte(3)
      ..write(obj.initialQuantity)
      ..writeByte(4)
      ..write(obj.buyingPrice)
      ..writeByte(5)
      ..write(obj.sellingPrice)
      ..writeByte(6)
      ..write(obj.mode)
      ..writeByte(7)
      ..write(obj.lowStockLimit)
      ..writeByte(8)
      ..write(obj.expectedTotalSales)
      ..writeByte(9)
      ..write(obj.totalBuyingCost)
      ..writeByte(10)
      ..write(obj.dateAdded);
  }
}

class AppSettingsAdapter extends TypeAdapter<AppSettings> {
  static const int typeIdValue = 3;

  @override
  final int typeId = typeIdValue;

  @override
  AppSettings read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }

    return AppSettings(
      language: fields[0] as String? ?? 'en',
      currency: fields[1] as String? ?? 'CNY',
      darkMode: fields[2] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.language)
      ..writeByte(1)
      ..write(obj.currency)
      ..writeByte(2)
      ..write(obj.darkMode);
  }
}
