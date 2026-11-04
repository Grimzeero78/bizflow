class MpesaParsedMessage {
  final String transactionId;
  final String type;
  final String category;
  final double amount;
  final double? balance;
  final double? fee;
  final double? fulizaBalance;
  final String party;
  final String? counterpartyPhone;
  final String? jumbeId;
  final String message;
  final int timestamp;

  const MpesaParsedMessage({
    required this.transactionId,
    required this.type,
    required this.category,
    required this.amount,
    required this.balance,
    required this.fee,
    required this.fulizaBalance,
    required this.party,
    required this.counterpartyPhone,
    required this.jumbeId,
    required this.message,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'transactionId': transactionId,
        'transactionCode': transactionId,
        'type': type,
        'category': category,
        'subType': category,
        'amount': amount,
        'balance': balance,
        'fee': fee,
        'fulizaBalance': fulizaBalance,
        'party': party,
        'counterpartyName': party,
        'counterpartyPhone': counterpartyPhone,
        'jumbeId': jumbeId,
        'message': message,
        'rawSms': message,
        'timestamp': timestamp,
      };
}

class MpesaMessageParser {
  MpesaMessageParser._();

  static final RegExp _transactionAnchor = RegExp(
    r'^\s*([A-Z0-9]{9,10})\s+(?:Confirmed|Imethibitishwa)\.',
    caseSensitive: false,
  );
  static final RegExp _swahiliAnchor =
      RegExp(r'^\s*Imethibitishwa\.', caseSensitive: false);
  static final RegExp _amountPattern = RegExp(
    r'\b(?:Ksh|KES)\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
  static final RegExp _maskedPhonePattern =
      RegExp(r'\b\d{4}[\d*]{3,6}\d{0,4}\b');

  static MpesaParsedMessage? parse(
    String message, {
    int? receivedAtMilliseconds,
  }) {
    final normalized = message.trim();
    if (normalized.isEmpty) return null;
    final lower = normalized.toLowerCase();

    if (_isIgnored(lower)) return null;

    final anchor = _transactionAnchor.firstMatch(normalized);
    final hasSwahiliAnchor = _swahiliAnchor.hasMatch(normalized);
    final isStandaloneAccountNotice = _isStandaloneAccountNotice(lower);
    if (anchor == null && !hasSwahiliAnchor && !isStandaloneAccountNotice) {
      return null;
    }

    final classification = _classify(lower);
    if (classification == null) return null;

    final amountMatch = _amountPattern.firstMatch(normalized);
    if (amountMatch == null) return null;
    final amount = _parseAmount(amountMatch.group(1));
    if (amount == null || amount <= 0) return null;

    final transactionId =
        anchor?.group(1)?.toUpperCase() ?? 'SMS-$receivedAtMilliseconds';
    final date = _parseMessageDate(normalized);
    final timestamp = date?.millisecondsSinceEpoch ??
        receivedAtMilliseconds ??
        DateTime.now().millisecondsSinceEpoch;

    return MpesaParsedMessage(
      transactionId: transactionId,
      type: classification.type,
      category: classification.category,
      amount: amount,
      balance: _extractAmount(
        normalized,
        RegExp(
          r'(?:New\s+M-PESA\s+balance\s+is|Baki\s+yako\s+ya\s+M-PESA\s+ni)\s*(?:Ksh|KES)\s*([\d,]+(?:\.\d{1,2})?)',
          caseSensitive: false,
        ),
      ),
      fee: _extractAmount(
        normalized,
        RegExp(
          r'(?:Transaction\s+cost|Ada)[,\s]*(?:Ksh|KES)\s*([\d,]+(?:\.\d{1,2})?)',
          caseSensitive: false,
        ),
      ),
      fulizaBalance: _extractAmount(
        normalized,
        RegExp(
          r'outstanding\s+Fuliza\s+balance\s+is\s*(?:Ksh|KES)\s*([\d,]+(?:\.\d{1,2})?)',
          caseSensitive: false,
        ),
      ),
      party: _extractParty(normalized, classification.category),
      counterpartyPhone:
          _maskedPhonePattern.firstMatch(normalized)?.group(0),
      jumbeId: RegExp(
        r'\bJumbeID\s*[:#]?\s*([A-Z0-9_-]+)',
        caseSensitive: false,
      ).firstMatch(normalized)?.group(1),
      message: normalized,
      timestamp: timestamp,
    );
  }

  static bool _isIgnored(String lower) {
    if (lower.contains('cancelled the reversal') ||
        lower.contains('canceled the reversal') ||
        lower.contains('cancelled reversal') ||
        lower.contains('canceled reversal') ||
        lower.contains('declined') ||
        lower.contains('failed') ||
        lower.contains('unsuccessful')) {
      return true;
    }
    if (lower.contains('jumbeid') && !lower.contains('new m-pesa balance')) {
      return true;
    }
    if (lower.contains('mini statement') ||
        lower.contains('mini-statement') ||
        lower.contains('check balance') ||
        lower.contains('balance inquiry')) {
      return true;
    }
    return false;
  }

  static bool _isStandaloneAccountNotice(String lower) =>
      (lower.contains('fuliza') &&
          (lower.contains('limit') || lower.contains('outstanding'))) ||
      (lower.contains('m-shwari') &&
          (lower.contains('overdue') ||
              lower.contains('interest earned') ||
              (lower.contains('loan') &&
                  (lower.contains('disbursed') ||
                      lower.contains('credited') ||
                      lower.contains('loan amount')))));

  static _Classification? _classify(String lower) {
    if (lower.contains('jumbeid') && lower.contains('new m-pesa balance')) {
      return const _Classification('transfer', 'jumbe_notification');
    }

    if ((lower.contains('reversal') || lower.contains('reversed')) &&
        (lower.contains('successfully reversed') ||
            lower.contains('has been reversed'))) {
      final isOutflow = lower.contains('deducted from your account') ||
          lower.contains('reversal outflow') ||
          lower.contains('received transaction has been reversed');
      return _Classification(
        isOutflow ? 'expense' : 'sale',
        isOutflow ? 'reversal_out' : 'reversal_in',
      );
    }

    if (lower.contains('m-shwari') && lower.contains('interest earned')) {
      return const _Classification('savings', 'interest_earned');
    }
    if (lower.contains('m-shwari') && lower.contains('overdue')) {
      return const _Classification('transfer', 'loan_overdue');
    }
    if (lower.contains('m-shwari') &&
        lower.contains('loan') &&
        (lower.contains('disbursed') ||
            lower.contains('credited') ||
            lower.contains('loan amount'))) {
      return const _Classification('transfer', 'loan_disbursement');
    }
    if (lower.contains('fuliza m-pesa amount')) {
      return const _Classification('expense', 'fuliza_usage');
    }
    if (lower.contains('fuliza') &&
        (lower.contains('limit') || lower.contains('outstanding'))) {
      return const _Classification('transfer', 'fuliza_liability');
    }

    if (lower.contains('m-shwari') &&
        lower.contains('transferred') &&
        lower.contains('to your m-shwari account')) {
      return const _Classification('savings', 'm_shwari_deposit');
    }
    if (lower.contains('m-shwari') &&
        lower.contains('transferred') &&
        lower.contains('from your m-shwari account')) {
      return const _Classification('savings', 'm_shwari_withdrawal');
    }
    if (lower.contains('loan repayment') ||
        lower.contains('repayment to m-shwari')) {
      return const _Classification('expense', 'loan_repayment');
    }

    if (lower.contains('umepokea') ||
        lower.contains('you have received') ||
        lower.contains('received from')) {
      return const _Classification('sale', 'money_in');
    }
    if (lower.contains('deposited to your account')) {
      return const _Classification('sale', 'agent_deposit');
    }
    if (lower.contains('paybill')) {
      return const _Classification('expense', 'paybill');
    }
    if (lower.contains('withdrawn at') || lower.contains('umetoa')) {
      return const _Classification('expense', 'withdrawal');
    }
    if (lower.contains('bought') && lower.contains('airtime')) {
      return const _Classification('expense', 'airtime');
    }
    if (lower.contains('paid to') || lower.contains('umelipa')) {
      return const _Classification('expense', 'buy_goods');
    }
    if (lower.contains('sent to') || lower.contains('umetuma')) {
      return const _Classification('expense', 'send_money');
    }
    return null;
  }

  static String _extractParty(String message, String category) {
    final pattern = switch (category) {
      'money_in' => RegExp(
          r'(?:\bfrom\b|\bkutoka\b)\s+(.+?)(?=\s+on\s+\d{1,2}/|\s+tarehe\b|$)',
          caseSensitive: false,
        ),
      'agent_deposit' => RegExp(
          r'deposited\s+to\s+your\s+account\s+by\s+(.+?)(?=\s+on\s+\d{1,2}/|$)',
          caseSensitive: false,
        ),
      'send_money' => RegExp(
          r'(?:sent\s+to|umetuma\s+pesa\s+kwa)\s+(.+?)(?=\s+on\s+\d{1,2}/|\s+kiasi\b|$)',
          caseSensitive: false,
        ),
      'paybill' => RegExp(
          r'sent\s+to\s+(.+?)\s+Paybill\b',
          caseSensitive: false,
        ),
      'buy_goods' => RegExp(
          r'(?:paid\s+to|umelipa)\s+(.+?)(?=\s+on\s+\d{1,2}/|$)',
          caseSensitive: false,
        ),
      'withdrawal' => RegExp(
          r'(?:withdrawn\s+at|umetoa)\s+(.+?)(?=\s+on\s+\d{1,2}/|$)',
          caseSensitive: false,
        ),
      _ => null,
    };
    if (pattern == null) return '';
    final match = pattern.firstMatch(message);
    if (match == null) return '';
    return match.group(1)?.replaceFirst(_maskedPhonePattern, '').trim() ?? '';
  }

  static double? _extractAmount(String text, RegExp pattern) {
    final match = pattern.firstMatch(text);
    return match == null ? null : _parseAmount(match.group(1));
  }

  static double? _parseAmount(String? value) =>
      value == null ? null : double.tryParse(value.replaceAll(',', ''));

  static DateTime? _parseMessageDate(String message) {
    final match = RegExp(
      r'\b(\d{1,2})/(\d{1,2})/(\d{2,4})\s+(?:(?:at|saa)\s+)?(\d{1,2}):(\d{2})\s*(AM|PM)?\b',
      caseSensitive: false,
    ).firstMatch(message);
    if (match == null) return null;

    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    var year = int.parse(match.group(3)!);
    if (year < 100) year += 2000;
    var hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final meridiem = match.group(6)?.toUpperCase();
    if (meridiem == 'PM' && hour < 12) hour += 12;
    if (meridiem == 'AM' && hour == 12) hour = 0;

    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > DateTime(year, month + 1, 0).day ||
        hour > 23 ||
        minute > 59) {
      return null;
    }
    return DateTime(year, month, day, hour, minute);
  }
}

class _Classification {
  final String type;
  final String category;

  const _Classification(this.type, this.category);
}
