import 'dart:async';
import 'dart:typed_data';
import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'translations.dart';
import 'app_database.dart';
import 'models.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:camera/camera.dart';
import 'package:confetti/confetti.dart';
import 'currency_detector.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
  ));

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppProvider()..loadData(),
      child: const MyApp(),
    ),
  );
}


class AppProvider extends ChangeNotifier {
  static const channel = MethodChannel('stockipa/sms');
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  final StreamController<String> _goalAchievedController = StreamController<String>.broadcast();

  List<Transaction> _transactions = [];
  List<StockItem> _stockItems = [];
  AppSettings _settings = AppSettings();
  bool _isBackgroundServiceRunning = false;
  final List<Map<String, dynamic>> _pendingIncomingTransactions = [];
  bool _isDataLoaded = false;
  DateTime? _lastGoalsSetDate;

  DateTime _currentDay = DateTime.now();
  final bool _smsPermissionGranted = true;
  final bool _notificationPermissionGranted = true;
  bool get smsPermissionGranted => _smsPermissionGranted;
  bool get notificationPermissionGranted => _notificationPermissionGranted;


  double _dailySaleTarget = 0;
  double _dailyExpenseLimit = 0;
  double _dailySavingTarget = 0;
  String _goalPeriod = 'daily';
  DateTime? _customStartDate;
  DateTime? _customEndDate;
  String get goalPeriod => _goalPeriod;
  double get dailySaleTarget => _dailySaleTarget;
  double get dailyExpenseLimit => _dailyExpenseLimit;
  double get dailySavingTarget => _dailySavingTarget;

  List<Transaction> get transactions => _transactions;
  List<StockItem> get stockItems => _stockItems;
  AppSettings get settings => _settings;
  bool get isBackgroundServiceRunning => _isBackgroundServiceRunning;
  Stream<String> get goalAchievedStream => _goalAchievedController.stream;

  Map<String, String> get translations {
    final defaultMap = translationsMap['en']!;
    final localeMap = translationsMap[_settings.language];
    if (localeMap == null) return defaultMap;
    return {...defaultMap, ...localeMap};
  }

  String getCurrencySymbol() {
    const symbols = {
      'USD': '\$',
      'KSH': 'KSh',
      'EUR': '€',
      'GBP': '£',
      'SAR': 'ر.س',
      'CNY': '¥',
      'INR': '₹',
      'JPY': '¥',
    };
    return symbols[_settings.currency] ?? '\$';
  }

  String formatAmount(num amount) {
    try {
      final double v = amount.toDouble();
      if (v == v.toInt()) {
        return v.toInt().toString();
      }
      return NumberFormat('#,##0.##', Intl.defaultLocale).format(v);
    } catch (e) {
      return amount.toString();
    }
  }

  String formatCurrency(num amount) {
    return '${getCurrencySymbol()}${formatAmount(amount)}';
  }

  void _setupMethodChannelListener() {
    try {
      channel.setMethodCallHandler((call) async {
        if (call.method == "onTransactionCaptured") {
          final data = Map<String, dynamic>.from(call.arguments);
          await _handleIncomingMpesa(data);
        }
      });
    } catch (e) {
      debugPrint("Error setting up MethodChannel: $e");
    }
  }

  Future<void> _initLocalNotifications() async {
    try {
      const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      final DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
      final InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _localNotifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          debugPrint('Notification tapped: ${response.payload}');
        },
      );
    } catch (e) {
      // Log error but don't crash the app; user just won't see notifications
      debugPrint('CRITICAL: Local notifications failed to initialize: $e');
    }
  }

  Future<bool> _ensureNotificationPermission() async {
    try {
      if (Platform.isAndroid) {
        return true;
      }
    } catch (_) {
      // If Platform check fails, fall back to permission handler below.
    }

    final status = await Permission.notification.status;
    if (status.isGranted) return true;
    final result = await Permission.notification.request();
    debugPrint('Notification permission after request: $result');
    return result.isGranted;
  }

  Future<void> _checkStockMovement(StockItem item) async {
    try {
      // Only check movement for countable items
      if (item.mode != 'countable') return;

      final now = DateTime.now();
      final sevenDaysAgo = now.subtract(const Duration(days: 7));

      // Get sales for this item
      final itemSales = _transactions.where((t) => 
        t.stockItemId == item.id && t.type == 'sale').toList();

      final recentSalesCount = itemSales.where((t) => t.date.isAfter(sevenDaysAgo)).length;
      final totalSold = itemSales.length;
      
      // Calculate Item Age
      final itemAgeDays = now.difference(item.dateAdded).inDays;
      
      final initialQty = item.initialQuantity > 0 ? item.initialQuantity : (item.quantity + totalSold);
      
      // Leverage Logic:
      // 1. Fast Moving: Sold > 30% of initial stock in the last 7 days
      final t = translations;
      if (initialQty > 0 && (recentSalesCount / initialQty) >= 0.3) {
        final String fastTitle = t['notification_fast_moving_stock_title'] ?? 'Fast Moving Stock';
        final String fastBody = (t['notification_fast_moving_stock_body'] ?? '{itemName} is selling fast! {count} sold this week.')
            .replaceAll('{itemName}', item.name)
            .replaceAll('{count}', recentSalesCount.toString());
        await _showMovementNotification(
          id: (item.id.hashCode + 1).remainder(100000),
          title: fastTitle,
          body: fastBody,
          channelId: 'stock_fast_move',
        );
        return; // Prioritize fast moving alert
      }

      // 2. Slow Moving: Item is > 14 days old and sold < 5% of initial stock
      if (itemAgeDays >= 14 && initialQty > 0 && (totalSold / initialQty) < 0.05) {
        final String slowTitle = t['notification_slow_moving_stock_title'] ?? 'Slow Moving Stock';
        final String slowBody = (t['notification_slow_moving_stock_body'] ?? '{itemName} hasn\'t moved much in 2 weeks. Consider a promotion.')
            .replaceAll('{itemName}', item.name);
        await _showMovementNotification(
          id: (item.id.hashCode + 2).remainder(100000),
          title: slowTitle,
          body: slowBody,
          channelId: 'stock_slow_move',
        );
      }
    } catch (e) {
      debugPrint('Movement check failed: $e');
    }
  }

  Future<void> _showMovementNotification({
    required int id,
    required String title,
    required String body,
    required String channelId,
  }) async {
    if (!await _ensureNotificationPermission()) return;

    final androidDetails = AndroidNotificationDetails(
      '${channelId}_v5',
      'Inventory Insights',
      channelDescription: 'Alerts for fast or slow moving inventory',
      importance: Importance.max,
      priority: Priority.max,
      color: channelId.contains('fast') ? Colors.orange : Colors.blue,
      playSound: true,
      enableLights: true,
      styleInformation: BigTextStyleInformation(body),
    );

    const iosDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true, presentBanner: true);
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _localNotifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  Future<void> _checkProfitGoalReached(StockItem item) async {
    try {
      if (!await _ensureNotificationPermission()) return;
      final t = translations;
      final symbol = getCurrencySymbol();
      
      // Calculate total actual sales for this specific item
      final double actualSales = _transactions
          .where((tx) => tx.stockItemId == item.id && tx.type == 'sale')
          .fold(0.0, (sum, tx) => sum + tx.amount);

      double target = 0.0;
      if (item.mode == 'countable') {
        // For countable, the target is the total value of initial stock at selling price
        target = item.initialQuantity * item.sellingPrice;
      } else {
        target = item.expectedTotalSales ?? 0.0;
      }

      if (target > 0 && actualSales >= target) {
        final int id = (item.id.hashCode + 3).remainder(100000);
        final String title = '${t['goalReached']}';
        final String body = '${t['profitGoalDesc']} ${item.name}! ${t['total']}: $symbol${formatAmount(actualSales)}';

        final androidDetails = AndroidNotificationDetails(
          'stockipa_goals_v5',
          'Milestones & Achievements',
          channelDescription: 'Alerts when sales targets are reached',
          importance: Importance.max,
          priority: Priority.max,
          enableLights: true,
          playSound: true,
          color: Colors.amber,
          styleInformation: BigTextStyleInformation(body),
        );
        const iosDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true, presentBanner: true);
        final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
        await _localNotifications.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: details,
        );
      }
    } catch (e) {
      debugPrint('Error checking profit goal: $e');
    }
  }

  Future<void> _showTransactionNotification(Transaction transaction) async {
    try {
      if (!await _ensureNotificationPermission()) return;

      final t = translations;
      final int id = DateTime.now().millisecondsSinceEpoch.remainder(100000);

      String title = 'Transaction Update';
      Color color = Colors.blue;
      if (transaction.type == 'sale') {
        title = t['saleAdded'] ?? 'Sale Captured!';
        color = Colors.blueAccent;
      } else if (transaction.type == 'savings') {
        title = t['savingsAdded'] ?? 'Savings Secured!';
        color = Colors.green;
      } else {
        title = t['expenseAdded'] ?? 'Expense Recorded';
        color = Colors.red;
      }

      final totals = getGoalPeriodTotals();
      final periodLabel = t[_goalPeriod] ?? (_goalPeriod[0].toUpperCase() + _goalPeriod.substring(1));

      // --- Notification 1: Transaction Details ---
      final String transBody = '${transaction.description}\nAmount: ${formatCurrency(transaction.amount)}';
      await _showSplitNotification(id, title, transBody, color);

      // --- Notification 2: Daily Totals Summary ---
      final today = DateTime.now();
      final dayTxs = _transactions.where((tx) => 
        tx.date.year == today.year && tx.date.month == today.month && tx.date.day == today.day).toList();
      final daySales = dayTxs.where((tx) => tx.type == 'sale').fold(0.0, (sum, tx) => sum + tx.amount);
      final dayExpenses = dayTxs.where((tx) => tx.type == 'expense').fold(0.0, (sum, tx) => sum + tx.amount);
      final daySavings = dayTxs.where((tx) => tx.type == 'savings').fold(0.0, (sum, tx) => sum + tx.amount);

      final String summaryTitle = 'Daily Summary ($periodLabel)';
      final String summaryBody = '${t['moneyIn'] ?? 'Money In'}: ${formatCurrency(daySales)}\n'
          '${t['totalExpenses'] ?? 'Expenses'}: ${formatCurrency(dayExpenses)}\n'
          '${t['savings'] ?? 'Savings'}: ${formatCurrency(daySavings)}\n\n'
          '${t['recent'] ?? 'Recent'}:\n${dayTxs.take(10).map((tx) => '${tx.type == 'sale' ? '+' : '-'} ${tx.description}').join('\n')}';
      await _showSplitNotification(9999, summaryTitle, summaryBody, Colors.blueGrey);

      // --- Notification 3: Business Goals Progress (if set) ---
      if (_dailySaleTarget > 0 || _dailyExpenseLimit > 0 || _dailySavingTarget > 0) {
        final goalLines = <String>[];
        if (_dailySaleTarget > 0) goalLines.add('${t['saleTarget'] ?? 'Sale'}: ${formatCurrency(totals['sales']!)} / ${formatCurrency(_dailySaleTarget)}');
        if (_dailyExpenseLimit > 0) goalLines.add('${t['expenseLimit'] ?? 'Limit'}: ${formatCurrency(totals['expenses']!)} / ${formatCurrency(_dailyExpenseLimit)}');
        if (_dailySavingTarget > 0) goalLines.add('${t['savingTarget'] ?? 'Saving'}: ${formatCurrency(totals['savings']!)} / ${formatCurrency(_dailySavingTarget)}');
        
        await _showSplitNotification(8888, 'Goal Progress ($periodLabel)', goalLines.join(' • '), Colors.orange);
      }
    } catch (e) {
      debugPrint('Error showing transaction notification: $e');
    }
  }

  Future<void> _showSplitNotification(int id, String title, String body, Color color) async {
    try {
      final androidDetails = AndroidNotificationDetails(
        'stockipa_transactions_v5',
        'Transaction Alerts',
        channelDescription: 'Notifications for added transactions',
        importance: Importance.max,
        priority: Priority.max,
        color: color,
        playSound: true,
        styleInformation: BigTextStyleInformation(body),
      );
      const iosDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true, presentBanner: true);
      final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

      await _localNotifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('Error showing split notification: $e');
    }
  }

  Future<void> _checkAndNotifyLowStock(StockItem item) async {
    try {
      if (item.mode != 'countable') return;
      if (!await _ensureNotificationPermission()) return;

      final int initial = item.initialQuantity > 0 ? item.initialQuantity : item.quantity;
      // Use custom limit if set, otherwise fallback to 30% of initial
      final int threshold = item.lowStockLimit ?? (initial * 0.3).ceil();
      
      if (threshold > 0 && item.quantity <= threshold) {
        final int id = DateTime.now().millisecondsSinceEpoch.remainder(100000);
        final t = translations;
        final String title = t['notification_low_stock_title'] ?? 'Low Stock Alert!';
        final double remainingPercent = initial > 0 ? ((item.quantity / initial) * 100) : 0;
        final String body = (t['notification_low_stock_body'] ?? '{itemName} is low: {quantity} left ({percent}%)')
            .replaceAll('{itemName}', item.name)
            .replaceAll('{quantity}', item.quantity.toString())
            .replaceAll('{percent}', remainingPercent.toStringAsFixed(0));

        final androidDetails = AndroidNotificationDetails(
          'stockipa_low_stock_v5',
          'Low Stock',
          channelDescription: 'Alerts when stock reaches low threshold',
          importance: Importance.max,
          priority: Priority.max,
          color: Colors.orange,
          playSound: true,
          styleInformation: BigTextStyleInformation(body),
        );
        const iosDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true, presentBanner: true);
        final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

        await _localNotifications.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: details,
        );
      }
    } catch (e) {
      debugPrint('Error showing low-stock notification: $e');
    }
  }

  /// Processes incoming M-PESA data. 
  /// Returns true if a new transaction was actually added.
  Future<bool> _handleIncomingMpesa(Map<String, dynamic> data, {bool silent = false}) async {
    try {
      if (!_isDataLoaded) {
        _pendingIncomingTransactions.add(data);
        return true;
      }

      final String rawType = data['type'] as String? ?? 'expense';
      // Map incoming categories to appropriate core types
      final String type = (rawType == 'sale' || rawType == 'income') 
          ? 'sale' 
          : (rawType == 'bank_saving' || rawType == 'savings' 
              ? 'savings' 
              : (rawType == 'transfer' || rawType == 'business_transfer' ? 'transfer' : 'expense'));
      final String? category = data['category'] as String?;
      final String? sourceTransactionId = data['transactionId'] as String?;
      final double amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
      final String party = data['party'] as String? ?? 'Unknown';
      final String message = data['message'] as String? ?? '';
      final int timestamp = data['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
      final double? balance = (data['balance'] as num?)?.toDouble();

      // Efficient lookup
      final bool exists = _transactions.any((t) {
        if (sourceTransactionId != null && t.sourceTransactionId == sourceTransactionId) return true;
        return t.date.millisecondsSinceEpoch == timestamp && 
               t.amount == amount && 
               t.type == type;
      });

      if (!exists && amount > 0) {
        final transaction = Transaction(
          id: '${timestamp}_${Random().nextInt(999)}',
          type: type,
          amount: amount,
          quantity: 1,
          description: message.isNotEmpty ? message : party,
          date: DateTime.fromMillisecondsSinceEpoch(timestamp),
          balance: balance,
          category: category,
          sourceTransactionId: sourceTransactionId,
        );

        _transactions.insert(0, transaction);
        
        if (!silent) {
          await _saveData();
          notifyListeners();
          _checkDailyGoals().ignore();
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint("Error handling incoming M-PESA: $e");
      return false;
    }
  }

  Future<void> checkServiceStatus() async {
    try {
      final bool running = await channel.invokeMethod('isServiceRunning');
      _isBackgroundServiceRunning = running;
      notifyListeners();
    } catch (e) {
      debugPrint("Error checking service status: $e");
    }
  }

  Future<void> syncMpesaTransactions() async {
    try {
      final List<dynamic>? list = await channel.invokeMethod('getStoredTransactions');
      if (list != null) {
        bool needsSave = false;
        for (var item in list) {
          if (await _handleIncomingMpesa(Map<String, dynamic>.from(item), silent: true)) {
            needsSave = true;
          }
        }
        if (needsSave) {
          await _saveData();
          notifyListeners();
          _checkDailyGoals().ignore();
        }
      }
      
      // Ensure background services are running
      if (_smsPermissionGranted) {
        await channel.invokeMethod('startSmsService');
        checkServiceStatus();
      }
    } catch (e, st) {
      debugPrint("Error syncing M-PESA: $e\n$st");
    }
  }

  Future<void> _loadFromDatabase() async {
    final db = await AppDatabase.instance;
    _transactions = await db.loadTransactions();
    _transactions.sort((a, b) => b.date.compareTo(a.date));

    _stockItems = await db.loadStockItems();
    _stockItems.sort((a, b) => b.dateAdded.compareTo(a.dateAdded));

    _settings = await db.loadSettings();
  }

  Future<void> loadData() async {
    try {
      _setupMethodChannelListener();
      await _loadFromDatabase();

      _isDataLoaded = true;

      try {
        Intl.defaultLocale = _settings.language;
        await initializeDateFormatting(_settings.language);
      } catch (e, st) {
        debugPrint("Error initializing locale: $e");
        debugPrint(st.toString());
      }

      // Process any transactions that arrived while the database was loading
      if (_pendingIncomingTransactions.isNotEmpty) {
        for (var data in _pendingIncomingTransactions) {
          await _handleIncomingMpesa(data, silent: true);
        }
        _pendingIncomingTransactions.clear();
        await _saveData();
      }

      await _initLocalNotifications();
      await _loadDailyGoals();
      notifyListeners();
    } catch (e, st) {
      debugPrint("CRITICAL: Failed to load app data: $e\n$st");
    }
    await syncMpesaTransactions();
    FlutterNativeSplash.remove();
  }

  Future<void> checkGoalsReset() async {
    final now = DateTime.now();
    // Check if the calendar day has changed
    if (now.day != _currentDay.day || now.month != _currentDay.month || now.year != _currentDay.year) {
      debugPrint("System: Midnight detected. Rolling over data...");
      _currentDay = now;
      await _loadDailyGoals(); // This will clear goals if period is daily
      notifyListeners(); // This forces Home and Tracking to refresh their date filters
    } else {
      await _loadDailyGoals();
    }
  }

  Future<void> _loadDailyGoals() async {
    final prefs = await SharedPreferences.getInstance();
    _goalPeriod = prefs.getString('goalPeriod') ?? 'daily';
    if (_goalPeriod == 'permanent') _goalPeriod = 'yearly'; // Migrate old value
    
    final lastSetDateStr = prefs.getString('lastGoalsSetDate') ?? '';
    final now = DateTime.now();

    bool shouldReset = false;
    if (lastSetDateStr.isNotEmpty) {
      final lastDate = DateTime.parse(lastSetDateStr);
      if (_goalPeriod == 'daily') {
        shouldReset = lastDate.day != now.day || lastDate.month != now.month || lastDate.year != now.year;
      } else if (_goalPeriod == 'weekly') {
        // Compare week numbers within the same year
        final lastWeek = DateFormat('w').format(lastDate);
        final curWeek = DateFormat('w').format(now);
        shouldReset = lastWeek != curWeek || lastDate.year != now.year;
      } else if (_goalPeriod == 'monthly') {
        shouldReset = lastDate.month != now.month || lastDate.year != now.year;
      } else if (_goalPeriod == 'yearly') {
        shouldReset = lastDate.year != now.year;
      }
    }

    if (shouldReset) {
      _dailySaleTarget = 0;
      _dailyExpenseLimit = 0;
      _dailySavingTarget = 0;
      _customStartDate = null;
      _customEndDate = null;
      _lastGoalsSetDate = null;
      await prefs.setDouble('dailySaleTarget', 0);
      await prefs.setDouble('dailyExpenseLimit', 0);
      await prefs.setDouble('dailySavingTarget', 0);
      await prefs.remove('lastGoalsSetDate');
      await prefs.remove('customStartDate');
      await prefs.remove('customEndDate');
    } else {
      _dailySaleTarget = prefs.getDouble('dailySaleTarget') ?? 0;
      _dailyExpenseLimit = prefs.getDouble('dailyExpenseLimit') ?? 0;
      _dailySavingTarget = prefs.getDouble('dailySavingTarget') ?? 0;
      final startStr = prefs.getString('customStartDate');
      final endStr = prefs.getString('customEndDate');
      if (startStr != null) _customStartDate = DateTime.parse(startStr);
      if (endStr != null) _customEndDate = DateTime.parse(endStr);
      if (lastSetDateStr.isNotEmpty) _lastGoalsSetDate = DateTime.parse(lastSetDateStr);
    }
  }
  
  Future<void> _syncGoalsToNative() async {
    try {
      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;
      
      // Calculate End Date based on period
      DateTime end;
      if (_goalPeriod == 'daily') {
        end = DateTime(now.year, now.month, now.day, 23, 59, 59);
      } else if (_goalPeriod == 'weekly') {
        end = now.add(Duration(days: 7 - now.weekday));
      } else if (_goalPeriod == 'monthly') {
        end = DateTime(now.year, now.month + 1, 0);
      } else if (_goalPeriod == 'yearly') {
        end = DateTime(now.year, 12, 31);
      } else {
        end = _customEndDate ?? now.add(const Duration(days: 30));
      }

      final List<Map<String, dynamic>> goals = [
        if (_dailySaleTarget > 0) {'id': 'sale_target', 'title': 'Sale Target', 'type': 'sale', 'targetAmount': _dailySaleTarget, 'startDate': nowMs, 'endDate': end.millisecondsSinceEpoch},
        if (_dailyExpenseLimit > 0) {'id': 'expense_limit', 'title': 'Expense Limit', 'type': 'expense', 'targetAmount': _dailyExpenseLimit, 'startDate': nowMs, 'endDate': end.millisecondsSinceEpoch},
        if (_dailySavingTarget > 0) {'id': 'saving_goal', 'title': 'Saving Goal', 'type': 'savings', 'targetAmount': _dailySavingTarget, 'startDate': nowMs, 'endDate': end.millisecondsSinceEpoch},
      ];

      for (var goalData in goals) {
        await AppProvider.channel.invokeMethod('setGoal', {'goal': jsonEncode(goalData)});
      }
    } catch (e) {
      debugPrint('Failed to sync goals to native: $e');
    }
  }

  Future<void> updateDailyGoals({
    double? sale,
    double? expense,
    double? saving,
    String? period,
    DateTime? customStart,
    DateTime? customEnd,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final t = translations;
    
    await prefs.reload();

    // Reset notification locks so user is alerted if new goals are already met
    await prefs.remove('notified_sale_goal');
    await prefs.remove('notified_expense_goal');
    await prefs.remove('notified_saving_goal');

    if (sale != null) { _dailySaleTarget = sale; await prefs.setDouble('dailySaleTarget', sale); }
    if (expense != null) { _dailyExpenseLimit = expense; await prefs.setDouble('dailyExpenseLimit', expense); }
    if (saving != null) { _dailySavingTarget = saving; await prefs.setDouble('dailySavingTarget', saving); }
    if (period != null) { _goalPeriod = period; await prefs.setString('goalPeriod', period); }
    if (customStart != null) {
      _customStartDate = customStart;
      await prefs.setString('customStartDate', customStart.toIso8601String());
    }
    if (customEnd != null) {
      _customEndDate = customEnd;
      await prefs.setString('customEndDate', customEnd.toIso8601String());
    }
    
    final now = DateTime.now();
    _lastGoalsSetDate = now;
    await prefs.setString('lastGoalsSetDate', now.toIso8601String());

    final List<String> summary = [];
    if (_dailySaleTarget > 0) summary.add('${t['sale'] ?? 'Sale'}: ${formatCurrency(_dailySaleTarget)}');
    if (_dailyExpenseLimit > 0) summary.add('${t['expenseLimit'] ?? 'Limit'}: ${formatCurrency(_dailyExpenseLimit)}');
    if (_dailySavingTarget > 0) summary.add('${t['savings'] ?? 'Saving'}: ${formatCurrency(_dailySavingTarget)}');
    
    final String periodLabel = t[_goalPeriod] ?? _goalPeriod;
    final String body = summary.isEmpty
        ? (t['notification_goals_reset_body'] ?? 'All targets reset')
        : (t['notification_goals_active_body'] ?? 'Targets for {period}: {summary}')
            .replaceAll('{period}', periodLabel)
            .replaceAll('{summary}', summary.join(", "));

    await _showGoalNotification(t['notification_goals_active_title'] ?? '🎯 Goals Active', body, 'goals_updated');
    await _syncGoalsToNative();
    await _checkDailyGoals();
    notifyListeners();
  }

  Map<String, double> getGoalPeriodTotals() {
    final today = DateTime.now();
    List<Transaction> periodTxs;

    // We only want transactions from the day the goals were set forward,
    // within the current period.
    final DateTime? effectiveSetDate = _lastGoalsSetDate;

    if (_goalPeriod == 'daily') {
      final periodStart = DateTime(today.year, today.month, today.day);
      final periodEnd = DateTime(today.year, today.month, today.day, 23, 59, 59);
      final actualStart = (effectiveSetDate != null && effectiveSetDate.isAfter(periodStart)) ? effectiveSetDate : periodStart;

      periodTxs = _transactions.where((t) => (t.date.isAtSameMomentAs(actualStart) || t.date.isAfter(actualStart)) && t.date.isBefore(periodEnd.add(const Duration(seconds: 1)))).toList();
    } else if (_goalPeriod == 'weekly') {
      final weekStart = DateTime(today.year, today.month, today.day).subtract(Duration(days: today.weekday - 1));
      final weekEnd = weekStart.add(const Duration(days: 7));

      final actualStart = (effectiveSetDate != null && effectiveSetDate.isAfter(weekStart)) 
          ? effectiveSetDate 
          : weekStart;

      periodTxs = _transactions.where((t) => (t.date.isAtSameMomentAs(actualStart) || t.date.isAfter(actualStart)) && t.date.isBefore(weekEnd)).toList();
    } else if (_goalPeriod == 'monthly') {
      final monthStart = DateTime(today.year, today.month, 1);
      final monthEnd = DateTime(today.year, today.month + 1, 1);

      final actualStart = (effectiveSetDate != null && effectiveSetDate.isAfter(monthStart)) 
          ? effectiveSetDate 
          : monthStart;

      periodTxs = _transactions.where((t) => (t.date.isAtSameMomentAs(actualStart) || t.date.isAfter(actualStart)) && t.date.isBefore(monthEnd)).toList();
    } else if (_goalPeriod == 'yearly') {
      final yearStart = DateTime(today.year, 1, 1);
      final yearEnd = DateTime(today.year + 1, 1, 1);

      final actualStart = (effectiveSetDate != null && effectiveSetDate.isAfter(yearStart)) 
          ? effectiveSetDate 
          : yearStart;

      periodTxs = _transactions.where((t) => (t.date.isAtSameMomentAs(actualStart) || t.date.isAfter(actualStart)) && t.date.isBefore(yearEnd)).toList();
    } else if (_goalPeriod == 'custom' && _customStartDate != null && _customEndDate != null) {
      final start = DateTime(_customStartDate!.year, _customStartDate!.month, _customStartDate!.day);
      final end = DateTime(_customEndDate!.year, _customEndDate!.month, _customEndDate!.day, 23, 59, 59);
      
      // Ensure custom goals also respect the "start fresh" rule if the start date is today
      final actualStart = (effectiveSetDate != null && effectiveSetDate.isAfter(start)) 
          ? effectiveSetDate 
          : start;

      periodTxs = _transactions.where((t) => (t.date.isAtSameMomentAs(actualStart) || t.date.isAfter(actualStart)) && t.date.isBefore(end.add(const Duration(seconds: 1)))).toList();
    } else {
      periodTxs = _transactions;
    }

    return {
      'sales': periodTxs.where((t) => t.type == 'sale').fold(0.0, (sum, t) => sum + t.amount),
      'expenses': periodTxs.where((t) => t.type == 'expense').fold(0.0, (sum, t) => sum + t.amount),
      'savings': periodTxs.where((t) => t.type == 'savings').fold(0.0, (sum, t) => sum + t.amount),
    };
  }

  Future<void> _checkDailyGoals() async {
    final prefs = await SharedPreferences.getInstance();
    final t = translations;
    await prefs.reload();

    final today = DateTime.now();
    final totals = getGoalPeriodTotals();
    final sales = totals['sales']!;
    final expenses = totals['expenses']!;
    final savings = totals['savings']!;

    String periodToken;
    if (_goalPeriod == 'daily') {
      periodToken = DateFormat('yyyy-MM-dd').format(today);
    } else if (_goalPeriod == 'weekly') {
      periodToken = DateFormat('yyyy-w').format(today);
    } else if (_goalPeriod == 'monthly') {
      periodToken = DateFormat('yyyy-MM').format(today);
    } else if (_goalPeriod == 'yearly') {
      periodToken = DateFormat('yyyy').format(today);
    } else {
      periodToken = 'custom';
    }

    // Check if already notified for this specific period instance
    final notifiedSale = prefs.getString('notified_sale_goal') == periodToken;
    final notifiedExpense = prefs.getString('notified_expense_goal') == periodToken;
    final notifiedSaving = prefs.getString('notified_saving_goal') == periodToken;

    final String periodLabel = t[_goalPeriod] ?? '${_goalPeriod[0].toUpperCase()}${_goalPeriod.substring(1)}';

    if (_dailySaleTarget > 0 && sales >= _dailySaleTarget && !notifiedSale) {
      await prefs.setString('notified_sale_goal', periodToken);
      _goalAchievedController.add('sale');
      final String title = (t['notification_sale_target_title'] ?? '{period} Sale Target Reached!')
          .replaceAll('{period}', periodLabel);
      final String body = (t['notification_sale_target_body'] ?? 'Amazing! You reached your target of {target}. Total: {total}')
          .replaceAll('{target}', formatCurrency(_dailySaleTarget))
          .replaceAll('{total}', formatCurrency(sales));
      _showGoalNotification(title, body, 'sale_target');
    }
    
    // Changed condition from > to >= as requested
    if (_dailyExpenseLimit > 0 && expenses >= _dailyExpenseLimit && !notifiedExpense) {
      await prefs.setString('notified_expense_goal', periodToken);
      _goalAchievedController.add('expense');
      final String title = (t['notification_expense_limit_title'] ?? '{period} Expense Limit Exceeded!')
          .replaceAll('{period}', periodLabel);
      final String body = (t['notification_expense_limit_body'] ?? 'Watch out! You spent {amount}, which is over your limit of {limit}')
          .replaceAll('{amount}', formatCurrency(expenses))
          .replaceAll('{limit}', formatCurrency(_dailyExpenseLimit));
      _showGoalNotification(title, body, 'expense_limit');
    }
    
    if (_dailySavingTarget > 0 && savings >= _dailySavingTarget && !notifiedSaving) {
      await prefs.setString('notified_saving_goal', periodToken);
      final String title = (t['notification_saving_target_title'] ?? '{period} Saving Goal Met!')
          .replaceAll('{period}', periodLabel);
      final String body = (t['notification_saving_target_body'] ?? 'Great job! You saved {saved}. Goal was {target}')
          .replaceAll('{saved}', formatCurrency(savings))
          .replaceAll('{target}', formatCurrency(_dailySavingTarget));
      _goalAchievedController.add('saving');
      _showGoalNotification(title, body, 'saving_target');
    }
  }

  Future<void> _showGoalNotification(String title, String body, String channelId) async {
    if (!await _ensureNotificationPermission()) return;

    try {
      // Define distinct sounds and vibration patterns based on the goal type
      Int64List? vibrationPattern;
      AndroidNotificationSound? androidSound;
      String? iosSound;

      if (channelId == 'expense_limit') {
        vibrationPattern = Int64List.fromList([0, 400, 200, 400, 200, 400, 200, 400]); // Aggressive Alarm
        androidSound = const RawResourceAndroidNotificationSound('expense_alert');
        iosSound = 'expense_alert.aiff';
      } else if (channelId == 'sale_target' || channelId == 'saving_target') {
        vibrationPattern = Int64List.fromList([0, 200, 100, 200]); // "Success" double-tap
        androidSound = const RawResourceAndroidNotificationSound('goal_success');
        iosSound = 'goal_success.aiff';
      } else {
        vibrationPattern = Int64List.fromList([0, 100]); // Subtle single tap for updates
      }

      final bool isExpenseAlert = channelId == 'expense_limit';
      
      final androidDetails = AndroidNotificationDetails(
        'daily_goals_${channelId}_v10', // Incremented to v10 to force the OS to refresh sound/vibration
        isExpenseAlert ? 'Daily Expense Alerts - URGENT' : 'Daily Goal Achievements', // Human-readable channel name
        channelDescription: isExpenseAlert 
            ? 'Urgent alarm alerts for expense limit exceeded'
            : 'Catchy alerts for daily business targets',
        importance: Importance.max,
        priority: Priority.max,
        audioAttributesUsage: isExpenseAlert ? AudioAttributesUsage.alarm : AudioAttributesUsage.notification,
        category: isExpenseAlert ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.promo,
        color: isExpenseAlert ? Colors.red : Colors.green,
        playSound: true,
        sound: androidSound,
        enableVibration: true,
        vibrationPattern: vibrationPattern,
        enableLights: true,
        ledColor: isExpenseAlert ? Colors.red : Colors.green,
        ledOnMs: isExpenseAlert ? 500 : 1000,
        ledOffMs: isExpenseAlert ? 300 : 500,
        styleInformation: BigTextStyleInformation(body),
        fullScreenIntent: isExpenseAlert ? true : false,
      );

      final iosDetails = DarwinNotificationDetails(
        presentAlert: true, 
        presentBadge: true, 
        presentSound: true, 
        presentBanner: true,
        sound: iosSound,
        interruptionLevel: isExpenseAlert ? InterruptionLevel.critical : InterruptionLevel.timeSensitive,
      );

      int notificationId;
      switch (channelId) {
        case 'sale_target': notificationId = 1001; break;
        case 'expense_limit': notificationId = 1002; break;
        case 'saving_target': notificationId = 1003; break;
        case 'goals_updated': notificationId = 1004; break;
        default: notificationId = DateTime.now().millisecondsSinceEpoch.remainder(100000);
      }

      await _localNotifications.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(android: androidDetails, iOS: iosDetails),
      );
    } catch (e) {
      debugPrint('Error showing goal notification: $e');
    }
  }

  Future<void> _saveData() async {
    try {
      final db = await AppDatabase.instance;
      await db.saveAll(
        transactions: _transactions,
        stockItems: _stockItems,
        settings: _settings,
      );
    } catch (e, st) {
      debugPrint('ERROR: Data save failed! $e');
      debugPrint(st.toString());
      rethrow;
    }
  }

  Future<void> addTransaction({
    required String type,
    required double amount,
    int quantity = 1,
    required String description,
    String? stockItemId,
    DateTime? customDate,
  }) async {
    try {
      final nowTs = DateTime.now().millisecondsSinceEpoch;
      final transaction = Transaction(
        id: '${nowTs}_${Random().nextInt(999)}',
        type: type,
        amount: amount,
        quantity: quantity,
        description: description,
        stockItemId: stockItemId,
        date: customDate ?? DateTime.now(),
      );

      _transactions.insert(0, transaction);

      StockItem? updatedStockItem;
      if (stockItemId != null) {
        final index = _stockItems.indexWhere((item) => item.id == stockItemId);
        if (index != -1) {
          final item = _stockItems[index];

          // Only reduce quantity for countable items. Savings don't usually affect inventory count.
          int newQty = item.quantity;
          if (item.mode == 'countable' && type != 'savings') {
            newQty = (type == 'sale' ? item.quantity - quantity : item.quantity + quantity).clamp(0, 999999);
          }

          _stockItems[index] = _recreateStockItem(item, quantity: newQty);
          updatedStockItem = _stockItems[index];
        }
      }
      await _saveData();
      notifyListeners();

      _showTransactionNotification(transaction).ignore();
      if (updatedStockItem != null) {
        _checkAndNotifyLowStock(updatedStockItem).ignore();
        _checkStockMovement(updatedStockItem).ignore();
        _checkProfitGoalReached(updatedStockItem).ignore();
      }
      _checkDailyGoals().ignore();
    } catch (e, st) {
      debugPrint('Transaction add failed: $e\n$st');
      rethrow; // Re-throw so the UI level catch block can show the SnackBar
    }
  }

  Future<void> updateTransaction({
    required String id,
    required double amount,
    required int quantity,
    required String description,
    String? type,
    String? stockItemId,
  }) async {
    try {
      final index = _transactions.indexWhere((t) => t.id == id);
      if (index != -1) {
        final old = _transactions[index];
        final newType = type ?? old.type;

        // Reverse impact of the old transaction on stock
        if (old.stockItemId != null) {
          final sIdx = _stockItems.indexWhere((s) => s.id == old.stockItemId);
          if (sIdx != -1) {
            final s = _stockItems[sIdx];
            if (s.mode == 'countable' && old.type != 'savings') {
              final revertedQty = (old.type == 'sale' ? s.quantity + old.quantity : s.quantity - old.quantity).clamp(0, 999999);
              _stockItems[sIdx] = _recreateStockItem(s, quantity: revertedQty);
            }
          }
        }

        // Update the transaction
        _transactions[index] = Transaction(
          id: old.id,
          type: newType,
          amount: amount,
          quantity: quantity,
          description: description,
          stockItemId: stockItemId,
          date: old.date,
          balance: old.balance,
          category: old.category,
          sourceTransactionId: old.sourceTransactionId,
        );

        // Apply impact of the updated transaction on stock
        if (stockItemId != null) {
          final sIdx = _stockItems.indexWhere((s) => s.id == stockItemId);
          if (sIdx != -1) {
            final s = _stockItems[sIdx];
            if (s.mode == 'countable' && newType != 'savings') {
              final newQty = (newType == 'sale' ? s.quantity - quantity : s.quantity + quantity).clamp(0, 999999);
              _stockItems[sIdx] = _recreateStockItem(s, quantity: newQty);
            }
          }
        }

        await _saveData();
        notifyListeners();
      }
    } catch (e, st) {
      debugPrint('ERROR: Failed to update transaction: $e');
      debugPrint(st.toString());
      rethrow;
    }
  }

  Future<void> deleteTransaction(String id) async {
    try {
      final index = _transactions.indexWhere((t) => t.id == id);
      if (index != -1) {
        final t = _transactions[index];

        // Reverse stock impact before deleting
        if (t.stockItemId != null) {
          final sIdx = _stockItems.indexWhere((s) => s.id == t.stockItemId);
          if (sIdx != -1) {
            final s = _stockItems[sIdx];
            if (s.mode == 'countable' && t.type != 'savings') {
              final restoredQty = (t.type == 'sale' ? s.quantity + t.quantity : s.quantity - t.quantity).clamp(0, 999999);
              _stockItems[sIdx] = _recreateStockItem(s, quantity: restoredQty);
            }
          }
        }

        _transactions.removeAt(index);
        await _saveData();
        notifyListeners();
      }
    } catch (e, st) {
      debugPrint('ERROR: Failed to delete transaction: $e');
      debugPrint(st.toString());
      rethrow;
    }
  }

  /// Helper to recreate a StockItem with modified properties
  StockItem _recreateStockItem(StockItem item, {int? quantity}) {
    return StockItem(
      id: item.id,
      name: item.name,
      quantity: quantity ?? item.quantity,
      initialQuantity: item.initialQuantity,
      buyingPrice: item.buyingPrice,
      sellingPrice: item.sellingPrice,
      mode: item.mode,
      lowStockLimit: item.lowStockLimit,
      expectedTotalSales: item.expectedTotalSales,
      totalBuyingCost: item.totalBuyingCost,
      dateAdded: item.dateAdded,
    );
  }

  Future<void> addStockItem({
    required String name,
    required int quantity,
    required double buyingPrice,
    required double sellingPrice,
    String mode = 'countable',
    int? lowStockLimit,
    double? expectedTotalSales,
    double? totalBuyingCost,}) async {
    try {
      final item = StockItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        quantity: quantity,
        initialQuantity: quantity,
        buyingPrice: buyingPrice,
        sellingPrice: sellingPrice,
        mode: mode,
        lowStockLimit: lowStockLimit,
        expectedTotalSales: expectedTotalSales,
        totalBuyingCost: totalBuyingCost,
        dateAdded: DateTime.now(),
      );

      _stockItems.insert(0, item);
      await _saveData();
      notifyListeners();
    } catch (e, st) {
      debugPrint('ERROR: Failed to add stock item: $e');
      debugPrint(st.toString());
      rethrow;
    }
  }

  Future<void> updateStockItem({
    required String id,
    required String name,
    required int quantity,
    required double buyingPrice,
    required double sellingPrice,
    required String mode,
    int? lowStockLimit,
    double? expectedTotalSales,
    double? totalBuyingCost,}) async {
    try {
      final index = _stockItems.indexWhere((item) => item.id == id);
      if (index != -1) {
        final old = _stockItems[index];
        _stockItems[index] = StockItem(
          id: old.id,
          name: name,
          quantity: quantity,
          initialQuantity: old.initialQuantity,
          buyingPrice: buyingPrice,
          sellingPrice: sellingPrice,
          mode: mode,
          lowStockLimit: lowStockLimit,
          expectedTotalSales: expectedTotalSales,
          totalBuyingCost: totalBuyingCost,
          dateAdded: old.dateAdded,
        );
        await _saveData();
        notifyListeners();
      }
    } catch (e, st) {
      debugPrint('ERROR: Failed to update stock item: $e');
      debugPrint(st.toString());
      rethrow;
    }
  }

  Future<void> deleteStockItem(String id) async {
    try {
      _stockItems.removeWhere((item) => item.id == id);
      await _saveData();
      notifyListeners();
    } catch (e, st) {
      debugPrint('ERROR: Failed to delete stock item: $e');
      debugPrint(st.toString());
      rethrow;
    }
  }

  Future<void> updateSettings({String? language, String? currency, bool? darkMode}) async {
    if (language != null) _settings.language = language;
    if (currency != null) _settings.currency = currency;
    if (darkMode != null) _settings.darkMode = darkMode;
    // update Intl locale immediately so formatting reflects language change
    try {
      Intl.defaultLocale = _settings.language;
      await initializeDateFormatting(_settings.language);
    } catch (e, st) {
      debugPrint("Error updating locale: $e");
      debugPrint(st.toString());
    }

    notifyListeners();
    await _saveData();
  }

  Future<void> clearAllData() async {
    try {
      _transactions.clear();
      _stockItems.clear();

      final db = await AppDatabase.instance;
      await db.clearAllData();

      notifyListeners();
  } catch (e, st) {
      debugPrint("Clear all data failed: $e");
      debugPrint(st.toString());
      rethrow;
    }
  }
}

// ==================== MAIN APP ====================

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, _) {
        return MaterialApp(
          title: 'StocKipa',
          debugShowCheckedModeBanner: false,
          // Force the app locale to the selected language so built-in
          // date/number formatting and platform widgets follow it.
          locale: Locale(provider.settings.language),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: languages.map((l) => Locale(l['code']!)).toList(),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF2563EB),
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFEFF6FF), // Matches your Home gradient start
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: provider.settings.darkMode ? ThemeMode.dark : ThemeMode.light,
          home: const MainScreen(),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  late final PageController _pageController;
  late ConfettiController _saleConfettiController;
  late ConfettiController _expenseConfettiController;
  late ConfettiController _savingConfettiController;
  bool _isFirstRun = false;
  bool _checkingFirstRun = true;
  Timer? _midnightRefreshTimer;

  // Define pages as a getter or within build to ensure they refresh with the context
  List<Widget> get _pages => [
        const HomePage(),
        const TrackingPage(),
        const StockPage(),
        const SettingsPage(),
      ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentIndex);
    WidgetsBinding.instance.addObserver(this);
    _initFirstRun();
    _saleConfettiController = ConfettiController(duration: const Duration(seconds: 1));
    _expenseConfettiController = ConfettiController(duration: const Duration(seconds: 1));
    _savingConfettiController = ConfettiController(duration: const Duration(seconds: 1));

    // Listen to goal achievements for confetti effect
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AppProvider>(context, listen: false).goalAchievedStream.listen((goalType) {
        if (_currentIndex == 0) { // Only play confetti if on Home screen
          switch (goalType) {
            case 'sale':
              _saleConfettiController.play();
              break;
            case 'expense':
              _expenseConfettiController.play();
              break;
            case 'saving':
              _savingConfettiController.play();
              break;
          }
        }
      });
    });

    // Start a timer to refresh the app state periodically (e.g., every minute)
    // This ensures daily goals and transaction lists reset at midnight even if the app stays open.
    _midnightRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkMidnightRefresh());
  }

  Future<void> _initFirstRun() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool('stockipa_first_run_shown') ?? false;
    if (mounted) {
      setState(() {
        _isFirstRun = !shown;
        _checkingFirstRun = false;
      });
    }

    // Check permissions status
    final smsGranted = await Permission.sms.isGranted;
    final notifGranted = await Permission.notification.isGranted;

    if (!shown || !smsGranted || !notifGranted) {
      // Trigger permissions automatically on first run OR if they are missing
      await _requestPermissionsAndSync();
    } else {
      await _checkPermissions();
    }
  }

  void _checkMidnightRefresh() {
    if (mounted) {
      Provider.of<AppProvider>(context, listen: false).checkGoalsReset();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _saleConfettiController.dispose();
    _midnightRefreshTimer?.cancel();
    _expenseConfettiController.dispose();
    _savingConfettiController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Only run banner/permission checks if the first-run gate is already done
      if (!_isFirstRun && !_checkingFirstRun) {
        Provider.of<AppProvider>(context, listen: false).checkGoalsReset();
        _checkPermissions();
      }
    }
  }

  Future<void> _checkPermissions() async {
    if (!mounted) return;

    final smsGranted = await Permission.sms.isGranted;

    if (!mounted) return;
    final provider = Provider.of<AppProvider>(context, listen: false);

    if (smsGranted) {
      try {
        await provider.syncMpesaTransactions();
        _triggerReliabilityCheck();
      } catch (e, st) {
        debugPrint('Error syncing M-PESA after permission change: $e');
        debugPrint(st.toString());
      }
    }
  }

  Future<void> _triggerReliabilityCheck() async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final prefs = await SharedPreferences.getInstance();
    
    // Condition 1: User has at least one transaction (Utility proven)
    if (provider.transactions.isEmpty) return;
    
    // Condition 1.5: Permissions must be granted, otherwise Banner handles it
    if (!await Permission.sms.isGranted || !await Permission.notification.isGranted) return;

    // Condition 2: Not already shown
    if (prefs.getBool('reliability_prompt_shown') ?? false) return;

    // Condition 3: Device is aggressive
    final isAggressive = await AppProvider.channel.invokeMethod<bool>('checkDeviceAggressiveness') ?? false;
    if (!isAggressive) return;

    if (!mounted) return;
    _showReliabilitySheet(prefs, provider);
  }

  void _showReliabilitySheet(SharedPreferences prefs, AppProvider provider) {
    final t = provider.translations;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 20), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
            Text(t['reliability_title'] ?? 'Keep instant transaction detection active', textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(t['reliability_body'] ?? 'Some phones may pause background activity to save battery. Enable protection settings for faster and more reliable alerts.', textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () { 
                  Navigator.pop(context); 
                  AppProvider.channel.invokeMethod('openAutoStartSettings'); 
                  AppProvider.channel.invokeMethod('askBatteryOptimization'); 
                  prefs.setBool('reliability_prompt_shown', true); 
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: Text(t['improve_reliability'] ?? 'Improve Reliability'),
              ),
            ),
            TextButton(onPressed: () { Navigator.pop(context); prefs.setBool('reliability_prompt_shown', true); }, child: Text(t['maybe_later'] ?? 'Maybe Later')),
            TextButton(
              onPressed: () { 
                Navigator.pop(context); 
                prefs.setBool('reliability_prompt_dismissed', true); 
                prefs.setBool('reliability_prompt_shown', true); 
              }, 
              child: Text(
                t['dont_show_again'] ?? "Don't show again", 
                style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white38 : Colors.grey[600], fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<Map<Permission, PermissionStatus>> _requestPermissionsAndSync() async {
    // Request permissions sequentially to ensure the OS triggers prompts reliably
    final smsStatus = await Permission.sms.request();
    final notificationStatus = await Permission.notification.request();
    // Request the third critical permission: Battery Optimization
    await AppProvider.channel.invokeMethod('askBatteryOptimization');
    
    final Map<Permission, PermissionStatus> statuses = {
      Permission.sms: smsStatus,
      Permission.notification: notificationStatus,
    };

    if (!mounted) return statuses;
    final appProvider = Provider.of<AppProvider>(context, listen: false);

    try {
      await appProvider.syncMpesaTransactions();
    } catch (e, st) {
      debugPrint('Error syncing M-PESA: $e');
      debugPrint(st.toString());
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('stockipa_first_run_shown', true);
    if (mounted) setState(() => _isFirstRun = false);

    return statuses;
  }

  Widget _buildPermissionGate() {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final t = provider.translations;
    
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 44,
                    backgroundColor: Colors.white24,
                    child: ClipOval(
                      child: Image.asset(
                        'assets/icon.png',
                        height: 64,
                        width: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.account_balance_wallet, size: 40, color: Colors.blue),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    t['appName'] ?? 'StocKipa',
                    style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                t['permissionRationale'] ?? 'To detect M-PESA messages and show transaction notifications, StocKipa needs access to SMS and Notifications.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton( // Now primarily acts as a manual retry if auto-popup fails
                  onPressed: () => _requestPermissionsAndSync(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Text(t['allow'] ?? 'Grant Permissions', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 40),
              const Text(
                '78',
                style: TextStyle(color: Colors.white24, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;

    if (_checkingFirstRun) {
      return const Scaffold(
        backgroundColor: Color(0xFF2563EB), // Primary brand color instead of black
        body: Center(
          child: CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_isFirstRun) return _buildPermissionGate();

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          PageView(
            physics: const ClampingScrollPhysics(),
            controller: _pageController,
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
            },
            children: _pages,
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _saleConfettiController,
              blastDirectionality: BlastDirectionality.explosive, // All directions
              shouldLoop: false, // Don't loop
              colors: const [
                Colors.green,
                Colors.yellow,
                Colors.lightGreenAccent,
              ],
              emissionFrequency: 0.05,
              numberOfParticles: 20, // number of particles to emit
              gravity: 0.3,
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _expenseConfettiController,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              colors: const [
                Colors.red,
                Colors.orange,
                Colors.deepOrangeAccent,
              ],
              emissionFrequency: 0.05,
              numberOfParticles: 20,
              gravity: 0.3,
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _savingConfettiController,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              colors: const [
                Colors.blue,
                Colors.lightBlueAccent,
                Colors.white,
              ],
              emissionFrequency: 0.05,
              numberOfParticles: 20, // number of particles to emit
              gravity: 0.3,
            ),
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0
          ? FloatingActionButton(
              onPressed: () => _showDailyGoalsForm(context),
              backgroundColor: const Color(0xFF2563EB),
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.add, color: Colors.white, size: 32),
            )
          : null,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) => _pageController.animateToPage(index,
                duration: const Duration(milliseconds: 250),
                curve: Curves.fastOutSlowIn),
            type: BottomNavigationBarType.fixed,
            selectedItemColor: Colors.blue,
            unselectedItemColor: Colors.grey,
            selectedFontSize: 12,
            unselectedFontSize: 12,
            elevation: 0,
            items: [
              BottomNavigationBarItem(
                icon: const Icon(Icons.home_rounded),
                label: t['home'] ?? 'Home',
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.trending_up_rounded),
                label: t['tracking'] ?? 'Tracking',
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.inventory_2_rounded),
                label: t['stock'] ?? 'Stock',
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.settings_rounded),
                label: t['settings'] ?? 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDailyGoalsForm(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const DailyGoalsForm(),
    );
  }
}

// ==================== HOME PAGE ====================

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;
    final currentDate = DateFormat.yMMMMEEEEd().format(DateTime.now());

    final today = DateTime.now();
    // Robust day-only filtering for the Homepage "Fresh Start"
    final todayTransactions = provider.transactions.where((tx) => 
      tx.date.year == today.year && 
      tx.date.month == today.month && 
      tx.date.day == today.day).toList();

    // Calculate Daily Totals for the summary cards (always resets at midnight)
    final dailySales = todayTransactions.where((tx) => tx.type == 'sale').fold(0.0, (sum, tx) => sum + tx.amount);
    final dailyExpenses = todayTransactions.where((tx) => tx.type == 'expense').fold(0.0, (sum, tx) => sum + tx.amount);
    final dailySavings = todayTransactions.where((tx) => tx.type == 'savings').fold(0.0, (sum, tx) => sum + tx.amount);
    final profit = dailySales - dailyExpenses;

    return Container(
      decoration: BoxDecoration( // Line 470
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? [const Color(0xFF0F172A), const Color(0xFF1E293B)]
              : [const Color(0xFFEFF6FF), const Color(0xFFE0E7FF), const Color(0xFFF3E8FF)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        'assets/icon.png',
                        height: 36,
                        width: 36,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.account_balance_wallet, size: 36, color: Colors.blue),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [Color(0xFF2563EB), Color(0xFF9333EA)],
                      ).createShader(bounds),
                      child: Text(
                        t['appName'] ?? 'StocKipa',
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  t['manageYourBusiness'] ?? 'Manage your business',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white70
                        : Colors.black54,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.white.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.calendar_today, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        currentDate,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _buildActionButton(
                    context: context,
                    label: t['addSale'] ?? 'Add Sale',
                    icon: Icons.trending_up_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF2563EB), Color(0xFF3B82F6), Color(0xFF60A5FA)],
                    ),
                    onTap: () => _showTransactionForm(context, 'sale'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildActionButton(
                    context: context,
                    label: t['addExpense'] ?? 'Add Expense',
                    icon: Icons.trending_down_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFFF43F5E), Color(0xFFE11D48), Color(0xFFEC4899)],
                    ),
                    onTap: () => _showTransactionForm(context, 'expense'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildActionButton(
              context: context,
              label: t['scanBill'] ?? 'Scan Bill / Currency',
              icon: Icons.camera_alt_rounded,
              gradient: const LinearGradient(
                colors: [Color(0xFF8B5CF6), Color(0xFF7C3AED), Color(0xFF6D28D9)],
              ),
              onTap: () => _handleBillScan(context),
            ),
            const SizedBox(height: 24),
            SummaryCards(
              totalSales: dailySales,
              totalExpenses: dailyExpenses,
              totalSavings: dailySavings,
              profit: profit,
            ),
            const GoalTrackerCard(),
            const SizedBox(height: 24),
            TransactionList(
              transactions: todayTransactions,
              onEdit: (transaction) => _showTransactionForm(
                context,
                transaction.type,
                editingTransaction: transaction,
              ),
              onDelete: (id) async {
                try {
                  await provider.deleteTransaction(id);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Delete failed: ${e.toString()}')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required BuildContext context,
    required String label,
    required IconData icon,
    required Gradient gradient,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
            color: gradient.colors.first.withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleBillScan(BuildContext context) async {
    final t = Provider.of<AppProvider>(context, listen: false).translations;
    // Request permissions on-demand when the button is clicked.
    // This triggers the system dialog for Camera and Notifications.
    final statuses = await [
      Permission.camera,
      Permission.notification,
    ].request();

    if (statuses[Permission.camera] != PermissionStatus.granted) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar( // Line 615
          SnackBar(content: Text(t['cameraPermissionRequired'] ?? 'Camera permission is required for scanning.')),
        );
      }
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    if (!context.mounted) return;
    
    final double? scannedAmount = await Navigator.push<double>( // Line 628
      context,
      MaterialPageRoute(
        builder: (context) => CameraScannerScreen(camera: cameras.first),
      ),
    );

    if (scannedAmount != null && context.mounted) {
      _showBillScanResultDialog(context, scannedAmount);
    }
  }

  void _showBillScanResultDialog(BuildContext context, double detectedAmount) {
    final provider = Provider.of<AppProvider>(context, listen: false);
    final t = provider.translations;
    final TextEditingController manualController = TextEditingController(
      text: detectedAmount % 1 == 0 ? detectedAmount.toInt().toString() : detectedAmount.toString(),
    );

    // Use standard currency denominations as suggestions
    final List<double> suggestions = [10, 20, 50, 100, 200, 500, 1000];
    if (detectedAmount > 0 && !suggestions.contains(detectedAmount)) {
      suggestions.add(detectedAmount);
    }
    suggestions.sort();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: EdgeInsets.only(
              top: 24,
              left: 24,
              right: 24,
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
                Text(t['confirmAmount'] ?? 'Confirm Amount', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                TextField(
                  controller: manualController,
                  textAlign: TextAlign.center,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.blue),
                  decoration: InputDecoration(
                    prefixText: provider.getCurrencySymbol(),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                    hintText: '0.00',
                  ),
                  onChanged: (val) => setModalState(() {}),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: suggestions.map((s) => ChoiceChip(
                    label: Text(provider.formatCurrency(s)),
                    selected: double.tryParse(manualController.text) == s,
                    onSelected: (sel) { 
                      if (sel) {
                        setModalState(() {
                          manualController.text = s % 1 == 0 ? s.toInt().toString() : s.toString();
                        });
                      }
                    },
                  )).toList(),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                        onPressed: () {
                          final val = double.tryParse(manualController.text) ?? 0.0;
                          Navigator.pop(context);
                          _showTransactionForm(context, 'sale', initialAmount: val);
                        },
                        child: Text(t['addSale'] ?? 'Add Sale'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                        onPressed: () {
                          final val = double.tryParse(manualController.text) ?? 0.0;
                          Navigator.pop(context);
                          _showTransactionForm(context, 'expense', initialAmount: val);
                        },
                        child: Text(t['addExpense'] ?? 'Add Expense'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        }
      ),
    );
  }

  void _showTransactionForm(BuildContext context, String type, {Transaction? editingTransaction, double? initialAmount}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TransactionForm(
        type: type,
        editingTransaction: editingTransaction,
        initialAmount: initialAmount,
      ),
    );
  }
}

class MpesaRichText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final Color? highlightColor;

  const MpesaRichText({super.key, required this.text, this.style, this.highlightColor});

  @override
  Widget build(BuildContext context) {
    final highlight = highlightColor ?? Theme.of(context).colorScheme.primary;
    final List<TextSpan> spans = [];
    final regex = RegExp(
      r'(Confirmed|sent to|paid to|received from|withdrawn|transferred|moved|Balance|KSh|KSH|KES|[\d,]+\.\d{2})',
      caseSensitive: false,
    );

    int lastMatchEnd = 0;
    for (final match in regex.allMatches(text)) {
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(text: text.substring(lastMatchEnd, match.start)));
      }
      spans.add(TextSpan(
        text: match.group(0),
        style: TextStyle(fontWeight: FontWeight.bold, color: highlight),
      ));
      lastMatchEnd = match.end;
    }
    if (lastMatchEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastMatchEnd)));
    }
    return Text.rich(TextSpan(children: spans), style: style);
  }
}

class ScannedValue {
  final double amount;
  final bool isHighConfidence;
  ScannedValue({required this.amount, required this.isHighConfidence});
}

// ==================== REAL-TIME OCR SCANNER ====================

class CameraScannerScreen extends StatefulWidget {
  final CameraDescription camera;
  const CameraScannerScreen({super.key, required this.camera});

  @override
  State<CameraScannerScreen> createState() => _CameraScannerScreenState();
}

class _CameraScannerScreenState extends State<CameraScannerScreen> {
  late CameraController _controller;
  CurrencyDetector? _detector;
  final FlutterTts _tts = FlutterTts();

  bool _isProcessing = false;
  bool _showFlash = false;
  bool _isModelLoaded = false;
  bool _isTorchOn = false;
  bool _isAutoMode = false;
  final List<ScannedValue> _scannedList = [];
  List<Recognition> _recognitions = [];

  @override
  void initState() {
    super.initState();
    // Using medium for faster AI inference and better real-time performance
    _controller = CameraController(widget.camera, ResolutionPreset.medium, enableAudio: false);
    _detector = CurrencyDetector();
    _detector!.loadModel().then((_) {
      if (mounted) setState(() => _isModelLoaded = true);
    }).catchError((e) {
      debugPrint('Model load error: $e');
    });
    _initTts();
    _controller.initialize().then((_) {
      if (!mounted) return;
      // Ensure focus is ready
      _controller.setFocusMode(FocusMode.auto);
      setState(() => {});
    }).catchError((e) {
      debugPrint('Camera initialization error: $e');
    });
  }

  Future<void> _initTts() async {
    final provider = Provider.of<AppProvider>(context, listen: false);
    String langCode = provider.settings.language;
    
    // Map basic language codes to standard locale strings required by TTS engines.
    // For example, 'sw' is mapped to 'sw-KE' to ensure Kenyan Swahili pronunciation.
    if (langCode == 'sw') langCode = 'sw-KE';
    if (langCode == 'en') langCode = 'en-US';

    await _tts.setLanguage(langCode);
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> _speak(String text) async {
    await _tts.speak(text);
  }

  @override
  void dispose() {
    if (_isTorchOn) _controller.setFlashMode(FlashMode.off);
    _controller.dispose();
    _detector?.close();
    super.dispose();
  }

  Future<void> _toggleFlash() async {
    if (!_controller.value.isInitialized) return;
    try {
      final newMode = _isTorchOn ? FlashMode.off : FlashMode.torch;
      await _controller.setFlashMode(newMode);
      setState(() => _isTorchOn = !_isTorchOn);
      AppProvider.channel.invokeMethod('toggleFlash', {'status': _isTorchOn}).ignore();
    } catch (e) { debugPrint('Flash toggle error: $e'); }
  }

  Future<void> _takePhotoAndProcess({bool silent = false}) async {
    if (_isProcessing || !_controller.value.isInitialized) return;
    
    if (mounted) {
      setState(() {
        _isProcessing = true;
        if (!silent) _showFlash = true;
      });
    }

    if (!silent) {
      // Trigger haptic feedback for physical confirmation of the manual capture
      HapticFeedback.mediumImpact();
      AppProvider.channel.invokeMethod('triggerCaptureFeedback').ignore();
    }

    try {
      XFile photo;
      // Use a faster capture method if possible or just standard takePicture
      // Note: We use takePicture in a loop for auto-mode to maintain quality
      photo = await _controller.takePicture();
      
      if (mounted) setState(() => _showFlash = false);

      if (!mounted) return;
      if (!_isModelLoaded || _detector == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wait... model is still loading.')));
        return; 
      }

      final provider = Provider.of<AppProvider>(context, listen: false);
      final List<Recognition> results = await _detector!.predict(File(photo.path));
      
      if (mounted) setState(() => _recognitions = results);

      if (results.isEmpty) {
        if (mounted && !silent) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(provider.translations['noResultsFound'] ?? 'Detection returned no results.')));
        }
        return;
      }

      final topResult = results.first;
      final label = topResult.label;
      final confidence = topResult.score;
      
      // Threshold tuning: 
      // Manual scan: > 25% (Be more permissive for manual taps)
      // Auto scan: > 65% for a reliable automatic "lock"
      final threshold = silent ? 0.65 : 0.25;

      if (confidence > threshold) {
        final parsed = double.tryParse(label.replaceAll(RegExp(r'[^0-9\.]'), ''));
        if (parsed != null) {
          // Retrieve the announcement template from translations.
          final announcement = (provider.translations['currencyAnnouncement'] ?? '{symbol} {amount}')
              .replaceAll('{symbol}', provider.getCurrencySymbol())
              .replaceAll('{amount}', provider.formatAmount(parsed));
          
          _speak(announcement);

          if (silent) {
             // In auto-mode, provide subtle feedback when a high-confidence match is found
             HapticFeedback.lightImpact();
          }
          setState(() => _scannedList.add(ScannedValue(
            amount: parsed, 
            isHighConfidence: confidence > 0.85,
          )));
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${provider.translations['unrecognizedCurrency'] ?? 'Unrecognized currency format.'} ($label)')));
        }
      } else if (mounted && !silent) {
        // Only show "unclear" messages for manual taps to avoid spamming in auto-mode
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(provider.translations['unclearDetection'] ?? 'Unclear detection. Try centering the bill or better lighting.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Capture Error: ${e.toString()}')));
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _showFlash = false;
        });

        // If auto-mode is still on and we haven't hit a high-confidence result yet, 
        // or we want to continue scanning more bills, schedule the next frame.
        if (_isAutoMode && mounted) {
          Future.delayed(const Duration(milliseconds: 500), () => _takePhotoAndProcess(silent: true));
        }
      }
    }
  }

  void _toggleAutoMode() {
    setState(() {
      _isAutoMode = !_isAutoMode;
      if (_isAutoMode) _takePhotoAndProcess(silent: true);
    });
  }

  // OCR analysis removed — model-based detection is used instead.

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final provider = Provider.of<AppProvider>(context, listen: false);
    final double totalAccumulated = _scannedList.fold(0, (sum, item) => sum + item.amount);
    final bool isReady = _controller.value.isInitialized && _isModelLoaded;
    final t = provider.translations;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(child: CameraPreview(_controller)),
          if (_recognitions.isNotEmpty)
            Positioned.fill(child: CustomPaint(painter: BoundingBoxPainter(_recognitions))),
          if (!isReady)
            Container(
              color: Colors.black87,
              child: Center(child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [const CircularProgressIndicator(color: Colors.white), const SizedBox(height: 16), Text(t['modelLoading'] ?? 'Preparing AI...', style: const TextStyle(color: Colors.white))],
              )),
            ),
          if (_showFlash && isReady)
            Positioned.fill(
              child: Container(color: Colors.white),
            ),
          Container(decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.2))), // Less tint for clarity
          Center(child: Container(width: 280, height: 180, decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2), borderRadius: BorderRadius.circular(20)))),
          Positioned(top: 60, left: 20, child: CircleAvatar(backgroundColor: Colors.black54, child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)))),
          Positioned(
            top: 60, 
            left: 80, 
            child: ChoiceChip(
              label: Text(_isAutoMode ? (t['autoOn'] ?? "AUTO: ON") : (t['autoOff'] ?? "AUTO: OFF"), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              selected: _isAutoMode,
              selectedColor: Colors.blueAccent,
              backgroundColor: Colors.black54,
              onSelected: (_) => _toggleAutoMode(),
            ),
          ),
          Positioned(
            top: 60, 
            right: 20, 
            child: CircleAvatar(
              backgroundColor: _isTorchOn ? Colors.yellow : Colors.black54, 
              child: IconButton(
                icon: Icon(_isTorchOn ? Icons.flash_on : Icons.flash_off, color: _isTorchOn ? Colors.black : Colors.white), 
                onPressed: _toggleFlash
              ))),
          Positioned(
            bottom: 30, left: 20, right: 20,
            child: Column(
              children: [
                if (_scannedList.isNotEmpty) ...[
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: _scannedList.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final item = entry.value;
                      return Chip(
                        avatar: Icon(Icons.circle, size: 10, color: item.isHighConfidence ? Colors.green : Colors.orange),
                        backgroundColor: Colors.white,
                        label: Text(
                          "${item.isHighConfidence ? 'High Confidence' : 'Best Guess'}: ${provider.formatCurrency(item.amount)}", 
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)
                        ),
                        onDeleted: () => setState(() => _scannedList.removeAt(idx)),
                        deleteIcon: const Icon(Icons.close, size: 14),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_isProcessing) const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FloatingActionButton.large(onPressed: _takePhotoAndProcess, backgroundColor: Colors.white, child: const Icon(Icons.camera_alt, color: Colors.blue, size: 40)),
                    if (_scannedList.isNotEmpty) ...[
                      const SizedBox(width: 20),
                      FloatingActionButton.extended(
                        onPressed: () => Navigator.pop(context, totalAccumulated),
                        backgroundColor: Colors.green,
                        label: Text(
                          "${t['useTotal'] ?? 'USE TOTAL'}: ${provider.formatCurrency(totalAccumulated)}", 
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)
                        ),
                        icon: const Icon(Icons.check, color: Colors.white),
                      ),
                    ]
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class BoundingBoxPainter extends CustomPainter {
  final List<Recognition> recognitions;
  BoundingBoxPainter(this.recognitions);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    for (var recognition in recognitions) {
      final rect = Rect.fromLTRB(
        recognition.location.left * size.width,
        recognition.location.top * size.height,
        recognition.location.right * size.width,
        recognition.location.bottom * size.height,
      );
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)), paint);
      
      final textSpan = TextSpan(
        text: "${recognition.label} ${(recognition.score * 100).toStringAsFixed(0)}%",
        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, backgroundColor: Colors.blueAccent),
      );
      final textPainter = TextPainter(text: textSpan, textDirection: ui.TextDirection.ltr);
      textPainter.layout();
      textPainter.paint(canvas, Offset(rect.left, rect.top - 20));
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
// ==================== TRACKING PAGE ====================

class TrackingPage extends StatefulWidget {
  const TrackingPage({super.key});

  @override
  State<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends State<TrackingPage> {
  int modeIndex = 0; // 0:daily,1:weekly,2:monthly,3:yearly
  String searchQuery = '';
  DateTime? filterDate;
  late final PageController modeController;

  @override
  void initState() {
    super.initState();
    modeController = PageController(initialPage: modeIndex);
  }

  @override
  void dispose() {
    modeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;

    // Build base filtered list by search text or selected date
      final filteredTransactions = provider.transactions.where((transaction) {
      final matchesSearch = searchQuery.isEmpty ||
          transaction.description
              .toLowerCase()
              .contains(searchQuery.toLowerCase()) ||
          transaction.amount.toString().contains(searchQuery);

      if (!matchesSearch) return false;
      if (filterDate != null) {
        // If a specific date is selected, only include that day's transactions
        final sel = filterDate!;
        return transaction.date.year == sel.year && transaction.date.month == sel.month && transaction.date.day == sel.day;
      }
      return true;
    }).toList();

    // mode controller initialized in initState

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? [const Color(0xFF0F172A), const Color(0xFF1E293B)]
              : [const Color(0xFFEFF6FF), const Color(0xFFE0E7FF)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Color(0xFF2563EB), Color(0xFF9333EA)],
              ).createShader(bounds),
              child: Text(
                t['tracking'] ?? 'Tracking',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t['viewSearchTransactions'] ?? 'View and search your transactions',
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white70
                    : Colors.black54,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.white.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 20,
                  ),
                ],
              ),
              child: TextField(
                onChanged: (value) => setState(() => searchQuery = value),
                decoration: InputDecoration(
                  hintText: t['search'] ?? 'Search...',
                  prefixIcon: const Icon(Icons.search),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(16),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (filterDate != null)
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => filterDate = null),
                        ),
                      IconButton(
                        icon: const Icon(Icons.calendar_today),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now().add(const Duration(days: 3650)),
                          );
                          if (picked != null) {
                            setState(() => filterDate = picked);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Daily High-Level Summary Card
            if (modeIndex == 0) Builder(builder: (context) {
              final today = DateTime.now();
              final todayTxs = provider.transactions.where((t) => 
                t.date.year == today.year && t.date.month == today.month && t.date.day == today.day).toList();
              final sales = todayTxs.where((t) => t.type == 'sale').fold(0.0, (sum, t) => sum + t.amount);
              final expenses = todayTxs.where((t) => t.type == 'expense').fold(0.0, (sum, t) => sum + t.amount);

              return Container(
                margin: const EdgeInsets.only(bottom: 20),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF4F46E5)]),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [BoxShadow(color: Colors.blue.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 5))],
                ),
                child: Column(
                  children: [
                    Text(t['dailySummary'] ?? 'Today\'s Performance', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    Builder(builder: (context) {
                      final savings = todayTxs.where((t) => t.type == 'savings').fold(0.0, (sum, t) => sum + t.amount);
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          buildCompactSummaryCol(t['moneyIn'] ?? 'Money In', sales, provider, Colors.white),
                          buildCompactSummaryCol(t['totalExpenses'] ?? 'Expenses', expenses, provider, Colors.white70),
                          buildCompactSummaryCol(t['savings'] ?? 'Savings', savings, provider, Colors.white70),
                        ],
                      );
                    }),
                  ],
                ),
              );
            }),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.white.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: ['daily', 'weekly', 'monthly', 'yearly'].asMap().entries.map((entry) {
                  final idx = entry.key;
                  final mode = entry.value;
                  final isSelected = modeIndex == idx;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() => modeIndex = idx);
                        modeController.animateToPage(idx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          gradient: isSelected
                              ? const LinearGradient(
                                  colors: [Color(0xFF2563EB), Color(0xFF4F46E5)],
                                )
                              : null,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          t[mode] ?? mode,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isSelected ? Colors.white : null,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 20),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                physics: const NeverScrollableScrollPhysics(), // Disable horizontal swiping
                controller: modeController,
                onPageChanged: (index) => setState(() => modeIndex = index),
                children: ['daily', 'weekly', 'monthly', 'yearly'].map((viewMode) {
                  List<Transaction> modeTransactions = List.from(filteredTransactions);
                  if (filterDate == null && viewMode == 'daily') {
                    final now = DateTime.now();
                    final todayStart = DateTime(now.year, now.month, now.day);
                    modeTransactions = modeTransactions.where((t) => !t.date.isBefore(todayStart)).toList();
                  }
                  final grouped = groupTransactions(modeTransactions, provider, viewMode);
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    children: grouped.entries.map((e) => buildGroupCard(context, e.key, e.value, provider)).toList(),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildCompactSummaryCol(String label, double amount, AppProvider provider, Color color, {bool isBold = false}) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: color.withValues(alpha: 0.7), fontSize: 10)),
        Text(provider.formatCurrency(amount),
            style: TextStyle(color: color, fontSize: 13, fontWeight: isBold ? FontWeight.bold : FontWeight.w500)),
      ],
    );
  }

  Map<String, List<Transaction>> groupTransactions(List<Transaction> transactions, AppProvider provider, String viewMode) {
    final Map<String, List<Transaction>> groups = {};

    for (var transaction in transactions) {
      String key;
      switch (viewMode) {
        case 'daily':
          key = DateFormat.yMMMMEEEEd(Intl.defaultLocale).format(transaction.date);
          break;
        case 'weekly':
          final transactionDate = transaction.date;
          // Calculate the start of the week (Monday)
          final weekStart = transactionDate.subtract(Duration(days: transactionDate.weekday - 1));
          // Calculate the end of the week (Sunday)
          final weekEnd = weekStart.add(const Duration(days: 6));
          final formattedWeekStart = DateFormat.MMMd(Intl.defaultLocale).format(weekStart);
          final formattedWeekEnd = DateFormat.MMMd(Intl.defaultLocale).format(weekEnd);
          final weekNum = getWeekOfMonth(transaction.date);
          final monthYear = DateFormat.yMMMM(Intl.defaultLocale).format(transaction.date);
          key = '${provider.translations['week'] ?? 'Week'} $weekNum, $monthYear ($formattedWeekStart - $formattedWeekEnd)';
          break;
        case 'monthly':
          key = DateFormat.yMMMM(Intl.defaultLocale).format(transaction.date);
          break;
        case 'yearly':
          key = DateFormat.y(Intl.defaultLocale).format(transaction.date);
          break;
        default:
          key = DateFormat.yMMMMd(Intl.defaultLocale).format(transaction.date);
      }

      groups.putIfAbsent(key, () => []);
      groups[key]!.add(transaction);
    }

    return groups;
  }

  int getWeekOfMonth(DateTime date) {
    // Strict day-of-month grouping: 1-7 (W1), 8-14 (W2), 15-21 (W3), 22-31 (W4+)
    return (((date.day - 1) / 7).floor() + 1).clamp(1, 4);
  }

  Widget buildGroupCard(BuildContext context, String period, List<Transaction> transactions, AppProvider provider) {
    final totalSales = transactions.where((t) => t.type == 'sale').fold(0.0, (sum, t) => sum + t.amount);
    final totalExpenses = transactions.where((t) => t.type == 'expense').fold(0.0, (sum, t) => sum + t.amount);
    final totalSavings = transactions.where((t) => t.type == 'savings').fold(0.0, (sum, t) => sum + t.amount);

    if (modeIndex == 3) {
      return buildYearlyReport(context, period, transactions, provider);
    }

    final t = provider.translations;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  period,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text(
                      "${t['moneyIn'] ?? 'Money In'}: ${provider.formatCurrency(totalSales)}",
                      style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      "${t['totalExpenses']}: ${provider.formatCurrency(totalExpenses)}",
                      style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      "${t['savings'] ?? 'Savings'}: ${provider.formatCurrency(totalSavings)}",
                      style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Separate manual entries and auto-captured (M-PESA) transactions so they don't mix
          () {
            final manualTxs = transactions.where((t) => t.sourceTransactionId == null).toList();
            final autoTxs = transactions.where((t) => t.sourceTransactionId != null).toList();
            final List<Widget> txWidgets = [];

            if (manualTxs.isNotEmpty) {
              txWidgets.add(Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  provider.translations['manualEntrySection'] ?? 'Manual Entries',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ));
              txWidgets.addAll(manualTxs.map((transaction) {
                final Color effectiveColor = transaction.type == 'sale'
                    ? Colors.blueAccent
                    : transaction.type == 'savings'
                        ? Colors.green
                        : Colors.red;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  tileColor: effectiveColor.withValues(alpha: 0.05),
                  title: Text(transaction.description, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  subtitle: Text(DateFormat.yMd().add_jm().format(transaction.date), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  trailing: Text(provider.formatCurrency(transaction.amount), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: effectiveColor)),
                );
              }).toList());
            }

            if (autoTxs.isNotEmpty) {
              txWidgets.add(Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  provider.translations['mpesaSection'] ?? 'M-Pesa / Auto-captured',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ));
              txWidgets.addAll(autoTxs.map((transaction) => buildTransactionTile(context, transaction, provider)).toList());
            }

            return Column(children: txWidgets);
          }(),
        ],
      ),
    );
  }

  Widget buildYearlyReport(BuildContext context, String period, List<Transaction> transactions, AppProvider provider) {
    final t = provider.translations;
    final symbol = provider.getCurrencySymbol();

    // Group transactions by month for the report
    final monthlyStats = List.generate(12, (index) {
      final month = index + 1;
      final monthTxs = transactions.where((tx) => tx.date.month == month).toList();
      final sales = monthTxs.where((tx) => tx.type == 'sale').fold(0.0, (sum, tx) => sum + tx.amount);
      final expenses = monthTxs.where((tx) => tx.type == 'expense').fold(0.0, (sum, tx) => sum + tx.amount);
      final savings = monthTxs.where((tx) => tx.type == 'savings').fold(0.0, (sum, tx) => sum + tx.amount);
      return {'month': month, 'sales': sales, 'expenses': expenses, 'savings': savings};
    });

    final double maxVal = monthlyStats.map((m) =>
        [m['sales'] as double, m['expenses'] as double, m['savings'] as double].reduce(max)).fold(0.0, max);
        
    final totalAllSales = transactions.where((tx) => tx.type == 'sale').fold(0.0, (sum, tx) => sum + tx.amount);
    final totalAllExpenses = transactions.where((tx) => tx.type == 'expense').fold(0.0, (sum, tx) => sum + tx.amount);
    final totalAllSavings = transactions.where((tx) => tx.type == 'savings').fold(0.0, (sum, tx) => sum + tx.amount);
    final totalSaved = totalAllSales - totalAllExpenses;
    final yearProfitLabel = totalSaved >= 0 ? (t['surplus'] ?? 'Surplus') : (t['overspent'] ?? 'Overspent');

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10)],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(period, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                Icon(Icons.analytics_outlined, color: Colors.blue.shade300),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                buildReportStat(t['moneyIn'] ?? 'Money In', totalAllSales, symbol, provider, Colors.blueAccent),
                buildReportStat(t['totalExpenses'] ?? 'Total Expenses', totalAllExpenses, symbol, provider, Colors.red),
                buildReportStat(t['savings'] ?? 'Savings', totalAllSavings, symbol, provider, Colors.green),
                buildReportStat(yearProfitLabel, totalSaved.abs(), symbol, provider, totalSaved >= 0 ? Colors.blue : Colors.orange),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // Simple visual chart
          Container(
            height: 120,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: monthlyStats.map((m) {
                final double sales = m['sales'] as double;
                final double expenses = m['expenses'] as double;
                final double savings = m['savings'] as double;
                final double sFactor = maxVal > 0 ? sales / maxVal : 0;
                final double eFactor = maxVal > 0 ? expenses / maxVal : 0;
                final double savFactor = maxVal > 0 ? savings / maxVal : 0;

                return Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (sales > 0)
                          Container(
                            width: 8,
                            height: (sFactor * 80).clamp(4, 80),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Colors.blue.shade700, Colors.blue.shade300],
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        const SizedBox(width: 2),
                        if (expenses > 0)
                          Container(
                            width: 8,
                            height: (eFactor * 80).clamp(4, 80),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Colors.red.shade700, Colors.red.shade300],
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        const SizedBox(width: 2),
                        if (savings > 0)
                          Container(
                            width: 8,
                            height: (savFactor * 80).clamp(4, 80),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Colors.green.shade700, Colors.green.shade400],
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DateFormat.MMM().format(DateTime(DateTime.now().year, m['month'] as int)),
                      style: const TextStyle(fontSize: 9, color: Colors.grey),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Table(
              columnWidths: const {
                0: FlexColumnWidth(1.2),
                1: FlexColumnWidth(1),
                2: FlexColumnWidth(1),
                3: FlexColumnWidth(1),
              },
              children: [
                TableRow(
                  children: [
                    Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2), child: Text(t['month'] ?? 'Month', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey))),
                    Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2), child: Text(t['moneyIn'] ?? 'In', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey))),
                    Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2), child: Text(t['shortExp'] ?? 'Exp', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey))),
                    Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2), child: Text(t['shortSav'] ?? 'Sav', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey))),
                  ],
                ),
                ...monthlyStats.where((m) => (m['sales'] as double) > 0 || (m['expenses'] as double) > 0 || (m['savings'] as double) > 0).map((m) {
                  final sales = m['sales'] as double;
                  final expenses = m['expenses'] as double;
                  final savings = m['savings'] as double;
                  return TableRow(
                    children: [
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2), child: Text(DateFormat.MMM().format(DateTime(DateTime.now().year, m['month'] as int)), style: const TextStyle(fontSize: 12))),
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2), child: Text(provider.formatAmount(sales), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2), child: Text(provider.formatAmount(expenses), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2), child: Text(provider.formatAmount(savings), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
                    ],
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget buildReportStat(String label, double amount, String symbol, AppProvider provider, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('$symbol${provider.formatAmount(amount)}',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  Widget buildTransactionTile(BuildContext context, Transaction transaction, AppProvider provider) {
    final bool isWithdrawal = transaction.category == 'withdrawal' || transaction.description.toLowerCase().contains('withdraw');
    final Color effectiveColor = transaction.type == 'sale'
        ? Colors.blueAccent
        : transaction.type == 'savings'
            ? Colors.green
            : Colors.red;
    final bool isIncomeLike = transaction.type == 'sale' || transaction.type == 'savings';
    final IconData icon = (isIncomeLike || isWithdrawal) ? Icons.trending_up_rounded : Icons.trending_down_rounded;

    return ListTile(
      tileColor: effectiveColor.withValues(alpha: 0.05),
      isThreeLine: true,
      leading: CircleAvatar(
        backgroundColor: effectiveColor.withValues(alpha: 0.2),
        child: Icon(
          icon,
          color: effectiveColor,
        ),
      ),
      title: MpesaRichText(
        text: transaction.description,
        highlightColor: effectiveColor,
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
      subtitle: Text(
        DateFormat.yMd().add_jm().format(transaction.date),
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      trailing: const Icon(Icons.chevron_right, size: 16),
    );
  }
}

// ==================== STOCK PAGE ====================

class StockPage extends StatelessWidget {
  const StockPage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;
    final symbol = provider.getCurrencySymbol();
    final hasStock = provider.stockItems.isNotEmpty;

    final totalValue = provider.stockItems.fold(
      0.0,
      (sum, item) => sum + (item.quantity * item.sellingPrice),
    );

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? [const Color(0xFF0F172A), const Color(0xFF1E293B)]
              : [const Color(0xFFEFF6FF), const Color(0xFFE0E7FF)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [Color(0xFF2563EB), Color(0xFF9333EA)],
                        ).createShader(bounds),
                        child: Text(
                          t['stockManagement'] ?? 'Inventory',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${provider.stockItems.length} ${t['items'] ?? 'items'} • ${t['total'] ?? 'Total'}: $symbol${provider.formatAmount(totalValue)}',
                        style: TextStyle(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white70
                              : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF2563EB), Color(0xFF4338CA), Color(0xFF4F46E5)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blue.withValues(alpha: 0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => showStockForm(context),
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.add, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              t['addStock'] ?? 'Add Stock',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (!hasStock)
              Container(
                padding: const EdgeInsets.all(48),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.white.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Icon(Icons.inventory_2_rounded, size: 80, color: Colors.grey.shade400),
                    const SizedBox(height: 16),
                    Text(
                      t['noStock'] ?? 'No Stock',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t['noStockDesc'] ?? 'Add some items to get started',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.75,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                itemCount: provider.stockItems.length,
                itemBuilder: (context, index) {
                  final item = provider.stockItems[index];
                  final isCountable = item.mode == 'countable';

                  // Cumulative actual sales for this item across its lifetime
                  double itemTotalSales = provider.transactions
                      .where((t) => t.stockItemId == item.id && t.type == 'sale')
                      .fold(0.0, (sum, t) => sum + t.amount);
                  
                  double expectedSales = 0.0;
                  double buyingCost = 0.0;
                  double actualProfit = 0.0;
                  double expectedProfit = 0.0;
                  double remainingTarget = 0.0;

                  if (isCountable) {
                    // Mode 1: Calculation based on total stock at start
                    expectedSales = item.initialQuantity * item.sellingPrice;
                    buyingCost = item.initialQuantity * item.buyingPrice;
                    expectedProfit = expectedSales - buyingCost;
                    actualProfit = itemTotalSales - (item.initialQuantity - item.quantity) * item.buyingPrice;
                    remainingTarget = expectedSales - itemTotalSales;
                  } else {
                    // Mode 2: Calculation based on user-defined lump sums
                    expectedSales = item.expectedTotalSales ?? 0.0;
                    buyingCost = item.totalBuyingCost ?? 0.0;
                    expectedProfit = expectedSales - buyingCost;
                    actualProfit = itemTotalSales - buyingCost;
                    remainingTarget = expectedSales - itemTotalSales;
                  }
                  
                  return Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                item.name,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            PopupMenuButton(
                              icon: const Icon(Icons.more_vert),
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  child: Text(t['edit'] ?? 'Edit'),
                                  onTap: () {
                                    if (!context.mounted) return;
                                    final parentContext = context;
                                    Future.delayed(Duration.zero, () {
                                      if (!parentContext.mounted) return;
                                      showStockForm(parentContext, item: item);
                                    });
                                  },
                                ),
                                PopupMenuItem(
                                  child: Text(t['delete'] ?? 'Delete'),
                                  onTap: () async {
                                    final currentContext = context;
                                    try {
                                      await Future.delayed(Duration.zero);
                                      if (!currentContext.mounted) return;
                                      await provider.deleteStockItem(item.id);
                                    } catch (e) {
                                      if (currentContext.mounted) {
                                        ScaffoldMessenger.of(currentContext).showSnackBar(
                                          SnackBar(content: Text('Delete failed: $e')),
                                        );
                                      }
                                    }
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                        const Spacer(),
                        buildInfoRow(isCountable ? (t['unitBuyingPrice'] ?? 'Unit Buying Price') : (t['totalBuyingCost'] ?? 'Total Buying Cost'), 
                            isCountable ? '$symbol${provider.formatAmount(item.buyingPrice)}' : '$symbol${provider.formatAmount(buyingCost)}'),
                        if (isCountable)
                          buildInfoRow(t['unitSellingPrice'] ?? 'Unit Selling Price', '$symbol${provider.formatAmount(item.sellingPrice)}'),
                        buildInfoRow(t['expectedTotalSales'] ?? 'Expected Money In', '$symbol${provider.formatAmount(expectedSales)}'),
                        buildInfoRow(t['expectedProfit'] ?? 'Exp. Profit', '$symbol${provider.formatAmount(expectedProfit)}', valueColor: Colors.blue),
                        const Divider(),
                        if (isCountable) 
                          buildInfoRow(t['quantity'] ?? 'Stock Left', '${item.quantity} / ${item.initialQuantity}'),
                        buildInfoRow(t['moneyIn'] ?? 'Money In', '$symbol${provider.formatAmount(itemTotalSales)}', valueColor: Colors.green),
                        buildInfoRow(t['remainingTarget'] ?? 'Rem. Target', 
                          '$symbol${provider.formatAmount(remainingTarget.clamp(0, double.infinity))}',
                          valueColor: remainingTarget > 0 ? Colors.orange : Colors.green),
                        if (!isCountable)
                          buildInfoRow(t['actualBalance'] ?? 'Actual Balance', '$symbol${provider.formatAmount(actualProfit)}',
                            valueColor: actualProfit >= 0 ? Colors.green : Colors.red),
                        if (remainingTarget <= 0)
                          const Padding(
                            padding: EdgeInsets.only(top: 4), // Line 1506
                            child: Text('✅', style: TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.bold)), // Updated below to use translation
                          ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget buildInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  void showStockForm(BuildContext context, {StockItem? item}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StockForm(editingItem: item),
    );
  }
}

// ==================== SETTINGS PAGE ====================

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? [const Color(0xFF0F172A), const Color(0xFF1E293B)]
              : [const Color(0xFFEFF6FF), const Color(0xFFE0E7FF)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            const SizedBox(height: 12),
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Color(0xFF2563EB), Color(0xFF9333EA)],
              ).createShader(bounds),
              child: Text(
                t['settings'] ?? 'Settings',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t['customizeExperience'] ?? 'Customize your experience',
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white70
                    : Colors.black54,
              ),
            ),
            const SizedBox(height: 24),
            buildSettingCard(
              context,
              icon: Icons.language,
              iconColor: Colors.blue,
              title: t['language'] ?? 'Language',
              subtitle: t['chooseLanguage'] ?? 'Choose your preferred language',
              child: DropdownButtonFormField<String>(
                key: ValueKey(provider.settings.language),
                initialValue: provider.settings.language,
                decoration: InputDecoration(
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                items: languages.map((lang) {
                  return DropdownMenuItem<String>(
                    value: lang['code'],
                    child: Text('${lang['name']} (${lang['currency']})'),
                  );
                }).toList(),
                onChanged: (String? newCode) {
                  if (newCode != null) {
                final selectedLang = languages.firstWhere((l) => l['code'] == newCode);
                    provider.updateSettings(
                      language: newCode,
                  currency: selectedLang['currency'],
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 16),
            buildSettingCard(
              context,
              icon: Icons.payments_outlined,
              iconColor: Colors.green,
              title: t['currency'] ?? 'Currency',
              subtitle: t['chooseCurrency'] ?? 'Select your preferred currency symbol',
              child: DropdownButtonFormField<String>(
                key: ValueKey(provider.settings.currency),
                initialValue: provider.settings.currency,
                decoration: InputDecoration(
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                items: const [
                  DropdownMenuItem(value: 'CNY', child: Text('Chinese Yuan (¥)')),
                  DropdownMenuItem(value: 'USD', child: Text('US Dollar (\$)')),
                  DropdownMenuItem(value: 'KSH', child: Text('Kenyan Shilling (KSh)')),
                  DropdownMenuItem(value: 'EUR', child: Text('Euro (€)')),
                  DropdownMenuItem(value: 'GBP', child: Text('British Pound (£)')),
                  DropdownMenuItem(value: 'SAR', child: Text('Saudi Riyal (ر.س)')),
                  DropdownMenuItem(value: 'INR', child: Text('Indian Rupee (₹)')),
                ],
                onChanged: (String? newCurrency) {
                  if (newCurrency != null) {
                    provider.updateSettings(currency: newCurrency);
                  }
                },
              ),
            ),
            const SizedBox(height: 16),
            buildSettingCard(
              context,
              icon: provider.settings.darkMode ? Icons.dark_mode : Icons.light_mode,
              iconColor: Colors.purple,
              title: t['darkMode']!,
              subtitle: provider.settings.darkMode ? (t['darkThemeEnabled'] ?? 'Dark theme enabled') : (t['lightThemeEnabled'] ?? 'Light theme enabled'),
              child: SwitchListTile(
                value: provider.settings.darkMode,
                onChanged: (value) => provider.updateSettings(darkMode: value),
                title: Text(t['darkMode']!),
              ),
            ),
            const SizedBox(height: 16),
            buildSettingCard(
              context,
              icon: Icons.delete_forever,
              iconColor: Colors.red,
              title: t['clearData'] ?? 'Clear Data',
              subtitle: t['removeDataDesc'] ?? 'Remove all transactions and stock',
              child: ElevatedButton(
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(t['clearData'] ?? 'Clear Data'),
                      content: Text(t['clearConfirm'] ?? 'Are you sure? This cannot be undone.'),
                      actions: [ // Line 1609
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(t['cancel'] ?? 'Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(t['clear'] ?? 'Clear', style: const TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                  if (!context.mounted) return;
                  if (confirm == true) {
                    try {
                      await provider.clearAllData();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error clearing data: $e')),
                        );
                      }
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: Text(t['clearData'] ?? 'Clear All Data'),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFEFF6FF), Color(0xFFE0E7FF)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [Color(0xFF2563EB), Color(0xFF9333EA)],
                    ).createShader(bounds),
                    child: const Text(
                      'StocKipa',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    provider.translations['dev_contact_title'] ?? 'Contact Support',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                  const SizedBox(height: 6),
                  Text(provider.translations['dev_contact_phone'] ?? 'Phone: +254 143 374 333', style: const TextStyle(color: Colors.black54)),
                  Text(provider.translations['dev_contact_email'] ?? 'Email: support@injuguna308@gmail.com', style: const TextStyle(color: Colors.black54)),
                  Text(provider.translations['dev_contact_whatsapp'] ?? 'WhatsApp: +254 114 255 987', style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 6),
                  Text(t['manageBusinessEase'] ?? 'Manage your business with ease', style: const TextStyle(color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildSettingCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

// ==================== WIDGETS ====================

class TransactionForm extends StatefulWidget {
  final String type;
  final Transaction? editingTransaction;
  final double? initialAmount;

  const TransactionForm({
    super.key,
    required this.type,
    this.editingTransaction,
    this.initialAmount,
  });

  @override
  State<TransactionForm> createState() => _TransactionFormState();
}

class _TransactionFormState extends State<TransactionForm> {
  late TextEditingController amountController;
  late TextEditingController descriptionController;
  late TextEditingController quantityController;
  late TextEditingController notesController;
  bool isSaving = false;
  String? selectedStockId;
  int previousQuantity = 1;

  @override
  void initState() {
    super.initState();
    amountController = TextEditingController(
      text: widget.editingTransaction != null
          ? (widget.editingTransaction!.amount % 1 == 0
              ? widget.editingTransaction!.amount.toInt().toString()
              : widget.editingTransaction!.amount.toString())
          : (widget.initialAmount != null
              ? (widget.initialAmount! % 1 == 0
                  ? widget.initialAmount!.toInt().toString()
                  : widget.initialAmount!.toString())
              : ''),
    );
    quantityController = TextEditingController(text: widget.editingTransaction?.quantity.toString() ?? '1');
    previousQuantity = int.tryParse(quantityController.text) ?? 1;
    quantityController.addListener(onQuantityChanged);
    isSaving = widget.editingTransaction?.type == 'savings';

    String desc = widget.editingTransaction?.description ?? '';
    String notes = '';
    // Extract notes if they were saved in the "Item (Notes)" format
    if (desc.contains(' (') && desc.endsWith(')')) {
      final parts = desc.split(' (');
      desc = parts[0];
      notes = parts[1].substring(0, parts[1].length - 1);
    }

    descriptionController = TextEditingController(text: desc);
    notesController = TextEditingController(text: notes);
    selectedStockId = widget.editingTransaction?.stockItemId;
  }

  void onQuantityChanged() {
    final newQty = int.tryParse(quantityController.text) ?? 1;
    if (newQty != previousQuantity && newQty > 0) {
      final currentAmount = double.tryParse(amountController.text) ?? 0.0;
      if (currentAmount > 0) {
        final unitPrice = currentAmount / previousQuantity;
        final newAmount = unitPrice * newQty;
        
        setState(() {
          amountController.text = newAmount % 1 == 0 
              ? newAmount.toInt().toString() 
              : newAmount.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
        });
      }
      previousQuantity = newQty;
    }
  }

  @override
  void dispose() {
    quantityController.removeListener(onQuantityChanged);
    amountController.dispose();
    descriptionController.dispose();
    quantityController.dispose();
    notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;
    final symbol = provider.getCurrencySymbol();
    final bool isMpesaUpdate = widget.editingTransaction?.sourceTransactionId != null;
    final String transactionTypeLabel = isMpesaUpdate 
        ? 'MPESA' 
        : (isSaving 
            ? (t['savings'] ?? 'Savings') 
            : (widget.type == 'sale' ? (t['sale'] ?? 'Sale') : (t['expense'] ?? 'Expense')));

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isMpesaUpdate 
                      ? 'MPESA' 
                      : '${widget.editingTransaction != null ? (t['edit'] ?? 'Edit') : (t['add'] ?? 'Add')} $transactionTypeLabel',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (widget.type == 'sale')
              LayoutBuilder(
                builder: (context, constraints) {
                  return DropdownMenu<StockItem>(
                    width: constraints.maxWidth,
                    controller: descriptionController,
                    label: Text('${t['itemName'] ?? 'Item Name'} (${t['optional'] ?? 'Optional'})', style: const TextStyle(fontWeight: FontWeight.bold)),
                    enableFilter: true,
                    requestFocusOnTap: true,
                    inputDecorationTheme: InputDecorationTheme(
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    onSelected: (StockItem? item) {
                      setState(() {
                        selectedStockId = item?.id;
                        if (item != null && widget.type == 'sale' && amountController.text.isEmpty) {
                          amountController.text = item.sellingPrice % 1 == 0 
                              ? item.sellingPrice.toInt().toString() 
                              : item.sellingPrice.toString();
                        }
                      });
                    },
                    dropdownMenuEntries: provider.stockItems.map((item) => DropdownMenuEntry<StockItem>(
                      value: item,
                      label: item.name,
                    )).toList(),
                  );
                },
              )
            else
              TextField(
                controller: descriptionController,
                decoration: InputDecoration(
                  labelText: '${t['itemName'] ?? 'Item Name'} (${t['optional'] ?? 'Optional'})',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: buildInputLabel(t['amount'] ?? 'Amount', symbol),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 1,
                  child: buildInputLabel(t['quantity'] ?? 'Qty', null),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      prefixText: symbol,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: quantityController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.type == 'expense') ...[
              const SizedBox(height: 16),
              SwitchListTile(
                title: Text(t['markAsSaving'] ?? "Mark as Saving", style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(t['markAsSavingDesc'] ?? "Transaction will be tracked as bank savings"),
                value: isSaving,
                onChanged: (val) => setState(() => isSaving = val),
              ),
            ],
            const SizedBox(height: 16),
            Text('${t['description'] ?? 'Additional Notes / Description'} (${t['optional'] ?? 'Optional'})',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: notesController,
              maxLines: 2,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.all(16),
                hintText: t['extraDetailsHint'] ?? 'Any extra details...',
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(t['cancel'] ?? 'Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      final amount = double.tryParse(amountController.text);
                      final qty = int.tryParse(quantityController.text) ?? 1;
                      if (amount != null && amount > 0 && qty > 0) {
                        final defaultName = isSaving
                            ? (t['saved'] ?? 'Saved')
                            : (widget.type == 'sale' ? (t['sale'] ?? 'Sale') : (t['expense'] ?? 'Expense'));
                        final name = descriptionController.text.trim().isEmpty
                            ? defaultName
                            : descriptionController.text.trim();

                        final combinedDesc = notesController.text.isEmpty 
                            ? name 
                            : "$name (${notesController.text})";
                        try {
                          if (widget.editingTransaction != null) {
                            await provider.updateTransaction(
                              id: widget.editingTransaction!.id,
                              amount: amount,
                              quantity: qty,
                              description: combinedDesc,
                              type: isSaving ? 'savings' : widget.type,
                              stockItemId: selectedStockId,
                            );
                          } else {
                            await provider.addTransaction(
                              type: isSaving ? 'savings' : widget.type,
                              amount: amount,
                              quantity: qty,
                              description: combinedDesc,
                              stockItemId: selectedStockId,
                            );
                          }
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Error: ${e.toString()}')),
                            );
                          }
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      backgroundColor: widget.type == 'sale' ? Colors.blueAccent : (isSaving ? Colors.green : Colors.red),
                      foregroundColor: Colors.white,
                    ),
                    child: Text(widget.editingTransaction != null ? (t['update'] ?? 'Update') : (t['add'] ?? 'Add')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildInputLabel(String label, String? prefix) {
    return Text(label, style: const TextStyle(fontWeight: FontWeight.bold));
  }
}

class GoalTrackerCard extends StatelessWidget {
  const GoalTrackerCard({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;
    final symbol = provider.getCurrencySymbol();
    
    final targetsSet = provider.dailySaleTarget > 0 || provider.dailyExpenseLimit > 0 || provider.dailySavingTarget > 0;
    if (!targetsSet) return const SizedBox.shrink();

    final totals = provider.getGoalPeriodTotals();
    final String periodLabel = t[provider.goalPeriod] ?? provider.goalPeriod;

    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: Theme.of(context).brightness == Brightness.dark
              ? [const Color(0xFF1E293B), const Color(0xFF0F172A)]
              : [Colors.white, const Color(0xFFF1F5F9)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
        ],
        border: Border.all(color: Colors.blue.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '🎯 ${t['activeGoals'] ?? 'Active Goals'} ($periodLabel)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const Icon(Icons.auto_graph, size: 18, color: Colors.blue),
            ],
          ),
          const SizedBox(height: 16),
          if (provider.dailySaleTarget > 0)
            buildGoalProgress(
              t['saleTarget'] ?? 'Sale Target',
              totals['sales']!,
              provider.dailySaleTarget,
              symbol,
              Colors.blue,
              provider,
            ),
          if (provider.dailyExpenseLimit > 0)
            buildGoalProgress(
              t['expenseLimit'] ?? 'Expense Limit',
              totals['expenses']!,
              provider.dailyExpenseLimit,
              symbol,
              Colors.red,
              provider,
              isLimit: true,
            ),
          if (provider.dailySavingTarget > 0)
            buildGoalProgress(
              t['savingTarget'] ?? 'Saving Goal',
              totals['savings']!,
              provider.dailySavingTarget,
              symbol,
              Colors.green,
              provider,
            ),
        ],
      ),
    );
  }

  Widget buildGoalProgress(String label, double current, double target, String symbol, Color color, AppProvider provider, {bool isLimit = false}) {
    final progress = (current / target).clamp(0.0, 1.0);
    final isMet = isLimit ? current <= target : current >= target;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
              Text(
                '${provider.formatCurrency(current)} / ${provider.formatCurrency(target)}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isMet ? Colors.green : (isLimit ? Colors.red : Colors.grey)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: color.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

class DailyGoalsForm extends StatefulWidget {
  const DailyGoalsForm({super.key});

  @override
  State<DailyGoalsForm> createState() => _DailyGoalsFormState();
}

class _DailyGoalsFormState extends State<DailyGoalsForm> {
  late TextEditingController saleController;
  late TextEditingController expenseController;
  late TextEditingController savingController;
  String selectedPeriod = 'daily';
  DateTime? customStart;
  DateTime? customEnd;

  @override
  void initState() {
    super.initState();
    final provider = Provider.of<AppProvider>(context, listen: false);
    saleController = TextEditingController(text: provider.dailySaleTarget > 0 ? provider.dailySaleTarget.toString() : '');
    expenseController = TextEditingController(text: provider.dailyExpenseLimit > 0 ? provider.dailyExpenseLimit.toString() : '');
    savingController = TextEditingController(text: provider.dailySavingTarget > 0 ? provider.dailySavingTarget.toString() : '');
    selectedPeriod = provider.goalPeriod;
    customStart = provider._customStartDate ?? DateTime.now();
    customEnd = provider._customEndDate ?? DateTime.now().add(const Duration(days: 7));
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;
    final symbol = provider.getCurrencySymbol();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 24, right: 24, top: 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(t['businessGoals'] ?? 'Business Goals', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
          const SizedBox(height: 16),
          Text(t['goalPeriod'] ?? 'Goal Period', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'daily', label: Text(t['daily'] ?? 'Daily')),
              ButtonSegment(value: 'weekly', label: Text(t['weekly'] ?? 'Weekly')),
              ButtonSegment(value: 'monthly', label: Text(t['monthly'] ?? 'Monthly')),
              ButtonSegment(value: 'yearly', label: Text(t['yearly'] ?? 'Yearly')),
              ButtonSegment(value: 'custom', label: Text(t['custom'] ?? 'Custom')),
            ],
            selected: {selectedPeriod},
            onSelectionChanged: (newSelection) => setState(() => selectedPeriod = newSelection.first),
          ),
          const SizedBox(height: 16),
          if (selectedPeriod == 'custom') ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: customStart ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        helpText: t['selectStartDate'] ?? 'Select Start Date',
                      );
                      if (picked != null) setState(() => customStart = picked);
                    },
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(customStart == null ? (t['startDate'] ?? 'Start Date') : DateFormat.yMMMd().format(customStart!)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: customEnd ?? DateTime.now(),
                        firstDate: customStart ?? DateTime(2000),
                        lastDate: DateTime(2100),
                        helpText: t['selectEndDate'] ?? 'Select End Date',
                      );
                      if (picked != null) setState(() => customEnd = picked);
                    },
                    icon: const Icon(Icons.event, size: 16),
                    label: Text(customEnd == null ? (t['endDate'] ?? 'End Date') : DateFormat.yMMMd().format(customEnd!)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          buildGoalField(t['saleTarget'] ?? 'Daily Sale Target', saleController, symbol, Colors.green),
          const SizedBox(height: 12),
          buildGoalField(t['expenseLimit'] ?? 'Daily Expense Limit', expenseController, symbol, Colors.red),
          const SizedBox(height: 12),
          buildGoalField(t['savingTarget'] ?? 'Daily Saving Target', savingController, symbol, Colors.blue),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                    // Request notification permission so goal alerts can appear
                    try {
                      final notifStatus = await Permission.notification.status;
                      if (!notifStatus.isGranted) {
                        final req = await Permission.notification.request();
                        if (!req.isGranted && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(t['enableNotifications'] ?? 'Enable notifications in system settings to receive goal alerts.')),
                          );
                        }
                      }
                    } catch (_) {}

                    await provider.updateDailyGoals(
                      sale: double.tryParse(saleController.text) ?? 0,
                      expense: double.tryParse(expenseController.text) ?? 0,
                      saving: double.tryParse(savingController.text) ?? 0,
                      period: selectedPeriod,
                      customStart: selectedPeriod == 'custom' ? customStart : null,
                      customEnd: selectedPeriod == 'custom' ? customEnd : null,
                    );
                    if (context.mounted) Navigator.pop(context);
                  },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(t['saveGoals'] ?? 'Save Business Goals', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget buildGoalField(String label, TextEditingController controller, String symbol, Color color) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        prefixText: '$symbol ',
        prefixStyle: TextStyle(color: color, fontWeight: FontWeight.bold),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: color, width: 2), borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class StockForm extends StatefulWidget {
  final StockItem? editingItem;

  const StockForm({super.key, this.editingItem});

  @override
  State<StockForm> createState() => _StockFormState();
}

class _StockFormState extends State<StockForm> {
  late TextEditingController nameController;
  late TextEditingController quantityController;
  late TextEditingController buyingPriceController;
  late TextEditingController sellingPriceController;
  late TextEditingController lowStockController;
  late TextEditingController expectedSalesController;
  late TextEditingController totalBuyingCostController;
  String selectedMode = 'countable';

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.editingItem?.name ?? '');
    quantityController = TextEditingController(text: widget.editingItem?.quantity.toString() ?? '');
    buyingPriceController = TextEditingController(text: widget.editingItem?.buyingPrice.toString() ?? '');
    sellingPriceController = TextEditingController(text: widget.editingItem?.sellingPrice.toString() ?? '');
    lowStockController = TextEditingController(text: widget.editingItem?.lowStockLimit?.toString() ?? '');
    expectedSalesController = TextEditingController(text: widget.editingItem?.expectedTotalSales?.toString() ?? '');
    totalBuyingCostController = TextEditingController(text: widget.editingItem?.totalBuyingCost?.toString() ?? '');
    
    selectedMode = widget.editingItem?.mode ?? 'countable';
  }

  @override
  void dispose() {
    nameController.dispose();
    quantityController.dispose();
    buyingPriceController.dispose();
    sellingPriceController.dispose();
    lowStockController.dispose();
    expectedSalesController.dispose();
    totalBuyingCostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;
    final symbol = provider.getCurrencySymbol();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${widget.editingItem != null ? (t['edit'] ?? 'Edit') : (t['add'] ?? 'Add')} ${t['stock'] ?? 'Stock'}',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(t['stockMode'] ?? 'Stock Mode', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'countable', label: Text(t['countable'] ?? 'Countable'), icon: const Icon(Icons.inventory_2)),
                ButtonSegment(value: 'target', label: Text(t['targetMode'] ?? 'Target'), icon: const Icon(Icons.track_changes)),
              ],
              selected: {selectedMode},
              onSelectionChanged: (newSelection) {
                setState(() {
                  selectedMode = newSelection.first;
                });
              },
            ),
            const SizedBox(height: 24),
            buildTextField(t['itemName'] ?? 'Item Name', nameController, required: true),
            const SizedBox(height: 16),
            
            if (selectedMode == 'countable') ...[
              buildTextField(t['quantity'] ?? 'Quantity', quantityController, keyboardType: TextInputType.number, required: true),
              const SizedBox(height: 16), // Line 1910
              buildTextField('${t['unitBuyingPriceFull'] ?? 'Unit Buying Price (per item)'} (${t['optional'] ?? 'Optional'})', buyingPriceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true), prefix: symbol),
              const SizedBox(height: 16), // Line 1913
              buildTextField('${t['unitSellingPriceFull'] ?? 'Unit Selling Price (per item)'} (${t['optional'] ?? 'Optional'})', sellingPriceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true), prefix: symbol),
              const SizedBox(height: 16),
              buildTextField('${t['lowStockLimit'] ?? 'Low Stock Limit'} (${t['optional'] ?? 'Optional'})', lowStockController,
                  keyboardType: TextInputType.number),
            ] else ...[
              buildTextField(t['totalBuyingCostLump'] ?? 'Total Buying Cost (lump sum)', totalBuyingCostController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true), prefix: symbol),
              const SizedBox(height: 16), // Line 1921
              buildTextField(t['expectedTotalSalesTarget'] ?? 'Expected Total Sales (target)', expectedSalesController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true), prefix: symbol),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(t['cancel'] ?? 'Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      if (nameController.text.isNotEmpty) {
                        final quantity = int.tryParse(quantityController.text) ?? 0;
                        final buyingPrice = double.tryParse(buyingPriceController.text) ?? 0.0;
                        final sellingPrice = double.tryParse(sellingPriceController.text) ?? 0.0;
                        
                        final lowLimit = int.tryParse(lowStockController.text);
                        final expSales = double.tryParse(expectedSalesController.text);
                        final totalBuy = double.tryParse(totalBuyingCostController.text);

                        if (quantity >= 0 || selectedMode == 'target') {
                          try {
                            if (widget.editingItem != null) {
                              await provider.updateStockItem(
                                id: widget.editingItem!.id,
                                name: nameController.text,
                                quantity: quantity,
                                buyingPrice: buyingPrice,
                                sellingPrice: sellingPrice,
                                mode: selectedMode,
                                lowStockLimit: lowLimit,
                                expectedTotalSales: expSales,
                                totalBuyingCost: totalBuy,
                              );
                            } else {
                              await provider.addStockItem(
                                name: nameController.text,
                                quantity: quantity,
                                buyingPrice: buyingPrice,
                                sellingPrice: sellingPrice,
                                mode: selectedMode,
                                lowStockLimit: lowLimit,
                                expectedTotalSales: expSales,
                                totalBuyingCost: totalBuy,
                              );
                            }
                            if (context.mounted) Navigator.pop(context);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error: ${e.toString()}')),
                              );
                            }
                          }
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(widget.editingItem != null ? (t['update'] ?? 'Update') : (t['add'] ?? 'Add')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildTextField(
    String label,
    TextEditingController controller, {
    TextInputType? keyboardType,
    String? prefix,
    bool required = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            prefixText: prefix,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ],
    );
  }
}

class SummaryCards extends StatelessWidget {
  final double totalSales;
  final double totalExpenses;
  final double totalSavings;
  final double profit;

  const SummaryCards({
    super.key,
    required this.totalSales,
    required this.totalExpenses,
    required this.totalSavings,
    required this.profit,
  });

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;
    final symbol = provider.getCurrencySymbol();

    // Calculate a meaningful progress value for the cards

    final profitProgress = (totalSales > 0) ? (profit / totalSales).clamp(0.0, 1.0) : 0.0;
    final String profitLabel = profit >= 0 ? (t['surplus'] ?? 'Surplus') : (t['overspent'] ?? 'Overspent');

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: buildCard(context, t['moneyIn'] ?? 'Money In', provider.formatAmount(totalSales), symbol, Icons.trending_up_rounded,
                const Color(0xFF2563EB), const Color(0xFF1D4ED8), 1.0)),
            const SizedBox(width: 12),
            Expanded(child: buildCard(context, t['totalExpenses'] ?? 'Total Expenses', provider.formatAmount(totalExpenses), symbol,
                Icons.trending_down_rounded, const Color(0xFFF43F5E), const Color(0xFFE11D48), (totalExpenses / (totalSales > 0 ? totalSales : 1)).clamp(0.0, 1.0))),
          ],
        ),
        const SizedBox(height: 12),
        buildCard(context, t['savings'] ?? "Bank Savings", provider.formatAmount(totalSavings), symbol, Icons.account_balance_rounded,
            const Color(0xFF10B981), const Color(0xFF059669), (totalSales > 0 ? (totalSavings / totalSales).clamp(0.0, 1.0) : 0.0)),
        const SizedBox(height: 12),
        buildCard(
          context,
          profitLabel,
          provider.formatAmount(profit.abs()),
          symbol,
          Icons.attach_money_rounded,
          profit >= 0 ? const Color(0xFF3B82F6) : const Color(0xFFF97316),
          profit >= 0 ? const Color(0xFF2563EB) : const Color(0xFFEA580C),
          profitProgress.clamp(0.0, 1.0),
        ),
      ],
    );
  }

  Widget buildCard(BuildContext context, String label, String formattedValue, String symbol, IconData icon, Color color1,
      Color color2, double progress) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [color1, color2]),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ShaderMask(
            shaderCallback: (bounds) => LinearGradient(colors: [color1, color2]).createShader(bounds),
            child: Text(
              '$symbol$formattedValue',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation(color1),
              minHeight: 4,
            ),
          ),
        ],
      ),
    );
  }
}

class TransactionList extends StatelessWidget {
  final List<Transaction> transactions;
  final Function(Transaction) onEdit;
  final Future<void> Function(String) onDelete;

  const TransactionList({
    super.key,
    required this.transactions,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    final t = provider.translations;
    final manualTxs = transactions.where((t) => t.sourceTransactionId == null).toList();
    final autoTxs = transactions.where((t) => t.sourceTransactionId != null).toList();

    if (transactions.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration( // Line 1900
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.white.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            Icon(Icons.receipt_long_rounded, size: 80, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              t['noTransactions'] ?? 'No Transactions',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              t['noTransactionsDesc'] ?? 'Your transactions will appear here',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t['allTransactions'] ?? 'All Transactions',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  '${transactions.length} ${t['total']}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (manualTxs.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(t['manualEntrySection'] ?? 'Manual Entries', 
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey)),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Table(
                columnWidths: const {
                  0: FlexColumnWidth(3),
                  1: FlexColumnWidth(1),
                  2: FlexColumnWidth(2),
                  3: IntrinsicColumnWidth(),
                },
                children: [
                  TableRow(
                    children: [
                      _buildTableHeader(t['itemName'] ?? 'Item'),
                      _buildTableHeader(t['qty'] ?? 'Qty'),
                      _buildTableHeader(t['amount'] ?? 'Amt'),
                      const SizedBox(),
                    ],
                  ),
                  ...manualTxs.map((tx) {
                    final Color color = tx.type == 'sale' ? Colors.blueAccent : (tx.type == 'savings' ? Colors.green : Colors.red);
                    return TableRow(
                      children: [
                        _buildTableCell(tx.description),
                        _buildTableCell(tx.quantity.toString()),
                        _buildTableCell(provider.formatCurrency(tx.amount), color: color, isBold: true),
                        _buildActionMenu(context, tx, t),
                      ],
                    );
                  }),
                ],
              ),
            ),
          ],
          if (manualTxs.isNotEmpty && autoTxs.isNotEmpty) const SizedBox(height: 32),
          if (autoTxs.isNotEmpty) ...[
            if (manualTxs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(t['mpesaSection'] ?? 'M-Pesa Transactions', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey)),
              ),
            ...autoTxs.map((transaction) {
              final bool isWithdrawal = transaction.category == 'withdrawal' || transaction.description.toLowerCase().contains('withdraw');
              final Color effectiveColor = transaction.type == 'sale'
                  ? Colors.blueAccent
                  : transaction.type == 'savings'
                      ? Colors.green
                      : Colors.red;
              final bool isIncomeLike = transaction.type == 'sale' || transaction.type == 'savings';
              final IconData icon = (isIncomeLike || isWithdrawal) ? Icons.trending_up_rounded : Icons.trending_down_rounded;

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                tileColor: effectiveColor.withValues(alpha: 0.05),
                trailing: _buildActionMenu(context, transaction, t, isMpesa: true),
                leading: CircleAvatar(
                  backgroundColor: effectiveColor.withValues(alpha: 0.2),
                  child: Icon(icon, color: effectiveColor, size: 20),
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MpesaRichText(
                      text: transaction.description,
                      highlightColor: effectiveColor,
                      style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14, height: 1.3),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${transaction.type == 'sale' 
                          ? (t['received'] ?? 'Received') 
                          : (transaction.type == 'savings' 
                              ? (t['deposited'] ?? 'Deposited') 
                              : (transaction.type == 'transfer' ? (t['moved'] ?? 'Moved') : (t['sent'] ?? 'Sent')))} '
                      '${provider.formatCurrency(transaction.amount)} • '
                      '${transaction.balance != null ? "Bal ${provider.formatCurrency(transaction.balance!)} • " : ""}'
                      '${DateFormat.yMd().add_jm().format(transaction.date)}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildTableHeader(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
    );
  }

  Widget _buildTableCell(String text, {Color? color, bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text, style: TextStyle(fontSize: 13, fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
    );
  }

  Widget _buildActionMenu(BuildContext context, Transaction transaction, Map<String, String> t, {bool isMpesa = false}) {
    return PopupMenuButton(
      icon: const Icon(Icons.more_vert, size: 20),
      itemBuilder: (context) => [
        PopupMenuItem(
          child: Text(isMpesa ? (t['update'] ?? 'Update') : (t['edit'] ?? 'Edit')),
          onTap: () {
            if (!context.mounted) return;
            final parentContext = context;
            Future.delayed(Duration.zero, () {
              if (!parentContext.mounted) return;
              onEdit(transaction);
            });
          },
        ),
        PopupMenuItem(
          child: Text(t['delete'] ?? 'Delete'),
          onTap: () async {
            if (!context.mounted) return;
            try {
              await Future.delayed(Duration.zero);
              if (!context.mounted) return;
              await onDelete(transaction.id);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Delete failed: $e')),
                );
              }
            }
          },
        ),
      ],
    );
  }
}

//haloo haloo this is the end it is finished