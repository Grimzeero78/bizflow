import 'package:flutter_test/flutter_test.dart';
import 'package:stockipa/mpesa_parser.dart';

void main() {
  group('MpesaMessageParser', () {
    test('extracts incoming transfers, amount, balance, masked sender and date',
        () {
      final parsed = MpesaMessageParser.parse(
        'UCOJQ9ZECD Confirmed. You have received Ksh500.00 from John Mwangi '
        '0722***712 on 24/3/26 at 12:20 PM New M-PESA balance is Ksh5,351.50.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.transactionId, 'UCOJQ9ZECD');
      expect(parsed.type, 'sale');
      expect(parsed.category, 'money_in');
      expect(parsed.amount, 500);
      expect(parsed.balance, 5351.5);
      expect(parsed.party, 'John Mwangi');
      expect(parsed.counterpartyPhone, '0722***712');
      expect(parsed.toMap()['subType'], 'money_in');
      expect(DateTime.fromMillisecondsSinceEpoch(parsed.timestamp),
          DateTime(2026, 3, 24, 12, 20));
    });

    test('extracts outflow fee separately from wallet balance', () {
      final parsed = MpesaMessageParser.parse(
        'ABCDE12345 Confirmed. Ksh150.00 sent to JOHN DOE 0722000000 '
        'on 23/6/23 at 3:41 PM. New M-PESA balance is Ksh1,205.10. '
        'Transaction cost, Ksh7.00.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.category, 'send_money');
      expect(parsed.amount, 150);
      expect(parsed.fee, 7);
      expect(parsed.balance, 1205.1);
      expect(parsed.party, 'JOHN DOE');
      expect(parsed.counterpartyPhone, '0722000000');
    });

    test('recognizes Paybill, Buy Goods, withdrawal, and airtime', () {
      final examples = <String, String>{
        'DY28XV679 Confirmed. Ksh4,000.00 sent to KCB Paybill AC for '
            'account 1137238445 on 9/9/23 at 11:31 PM.': 'paybill',
        'GH78KT901 Confirmed. Ksh500.00 paid to Naivas Supermarket on '
                '15/1/25 at 10:15 AM. New M-PESA balance is Ksh3,400.00.':
            'buy_goods',
        'ABCDE12345 Confirmed. Ksh100.00 withdrawn at Agent One on '
            '1/2/25 at 9:00 AM. Transaction cost, Ksh10.00.': 'withdrawal',
        'ABCDE12345 Confirmed. You bought Ksh50.00 airtime on '
            '1/2/25 at 9:00 AM.': 'airtime',
      };

      for (final entry in examples.entries) {
        expect(MpesaMessageParser.parse(entry.key)?.category, entry.value);
      }
    });

    test(
        'extracts Fuliza usage without treating its outstanding balance as wallet balance',
        () {
      final parsed = MpesaMessageParser.parse(
        'ABCDE12345 Confirmed. Fuliza M-PESA amount is Ksh200.00. '
        'Your outstanding Fuliza balance is Ksh700.00.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.type, 'expense');
      expect(parsed.category, 'fuliza_usage');
      expect(parsed.amount, 200);
      expect(parsed.balance, isNull);
      expect(parsed.fulizaBalance, 700);
    });

    test('classifies M-Shwari movements and loan obligations separately', () {
      expect(
        MpesaMessageParser.parse(
          'ABCDE12345 Confirmed. You have transferred Ksh300.00 from your '
          'M-PESA account to your M-Shwari account on 1/2/25 at 9:00 AM.',
        )?.category,
        'm_shwari_deposit',
      );
      expect(
        MpesaMessageParser.parse(
          'ABCDE12345 Confirmed. You have transferred Ksh300.00 from your '
          'M-Shwari account on 1/2/25 at 9:00 AM.',
        )?.category,
        'm_shwari_withdrawal',
      );
      expect(
        MpesaMessageParser.parse(
          'ABCDE12345 Confirmed. Ksh300.00 loan repayment to M-Shwari on '
          '1/2/25 at 9:00 AM.',
        )?.category,
        'loan_repayment',
      );
      expect(
        MpesaMessageParser.parse(
          'Your KSh500.00 M-Shwari loan is overdue. Pay now via *234#.',
        )?.category,
        'loan_overdue',
      );
      expect(
        MpesaMessageParser.parse(
          'M-Shwari loan amount KES1,000.00 has been credited to your account.',
        )?.category,
        'loan_disbursement',
      );
      expect(
        MpesaMessageParser.parse(
          'M-Shwari interest earned Ksh25.00 has been credited.',
        )?.category,
        'interest_earned',
      );
    });

    test('classifies Swahili transactions and successful reversals', () {
      expect(
        MpesaMessageParser.parse(
          'ABCDE12345 Imethibitishwa. Umepokea Ksh250.00 kutoka Jane Doe '
          '0712345678 tarehe 24/3/26 saa 12:20 PM Baki yako ya M-PESA ni '
          'Ksh500.00.',
        )?.category,
        'money_in',
      );
      expect(
        MpesaMessageParser.parse(
          'ABCDE12345 Confirmed. Reversal of transaction ZYXWV98765 has '
          'been successfully reversed. Ksh500.00 has been returned.',
        )?.category,
        'reversal_in',
      );
      expect(
        MpesaMessageParser.parse(
          'ABCDE12345 Confirmed. The received transaction has been reversed. '
          'Ksh500.00 deducted from your account.',
        )?.category,
        'reversal_out',
      );
    });

    test('extracts JumbeID while retaining the unique transaction code', () {
      final parsed = MpesaMessageParser.parse(
        'ABCDE12345 Confirmed. Ksh500.00 paid to Shop on 1/2/25 at 9:00 AM. '
        'JumbeID JMB123 New M-PESA balance is Ksh1,000.00.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.transactionId, 'ABCDE12345');
      expect(parsed.jumbeId, 'JMB123');
      expect(parsed.toMap()['transactionCode'], 'ABCDE12345');
    });

    test(
        'rejects promotional, failed, reversal-cancellation, and Jumbe duplicate SMS',
        () {
      const ignored = [
        'Dear Customer, you have cancelled the reversal of ABCDE12345 of '
            'Ksh100.00 from 0722000000.',
        'ABCDE12345 Confirmed. Your transaction failed due to a network error.',
        'ABCDE12345 Confirmed. JumbeID NK_74 Ksh500.00 paid to Shop.',
        'Get cashback today! Ksh100 bonus on your next purchase.',
        'Your M-PESA balance is Ksh1,000.00.',
      ];

      for (final message in ignored) {
        expect(MpesaMessageParser.parse(message), isNull, reason: message);
      }
    });
  });
}
