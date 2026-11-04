import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_database.dart';

class FinanceYearlyChart extends StatefulWidget {
  final int year;
  final String currencySymbol;

  const FinanceYearlyChart({
    super.key,
    required this.year,
    required this.currencySymbol,
  });

  @override
  State<FinanceYearlyChart> createState() => _FinanceYearlyChartState();
}

class _FinanceYearlyChartState extends State<FinanceYearlyChart> {
  late Future<List<Map<String, Object?>>> _summary;

  @override
  void initState() {
    super.initState();
    _summary =
        AppDatabase.instance.then((db) => db.getYearlySummary(widget.year));
  }

  @override
  void didUpdateWidget(covariant FinanceYearlyChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.year != widget.year) {
      _summary =
          AppDatabase.instance.then((db) => db.getYearlySummary(widget.year));
    }
  }

  @override
  Widget build(BuildContext context) {
    final months = List<double>.generate(12, (_) => 0);
    final expensesByMonth = List<double>.generate(12, (_) => 0);
    final savingsByMonth = List<double>.generate(12, (_) => 0);

    return FutureBuilder<List<Map<String, Object?>>>(
      future: _summary,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Could not load yearly totals: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        var incomeTotal = 0.0;
        var expenseTotal = 0.0;
        var savingsTotal = 0.0;
        for (final row in snapshot.data!) {
          final month = (row['month'] as num).toInt() - 1;
          if (month < 0 || month >= 12) continue;
          final income = (row['total_income'] as num?)?.toDouble() ?? 0;
          final expenses = (row['total_expense'] as num?)?.toDouble() ?? 0;
          final savings = (row['total_savings'] as num?)?.toDouble() ?? 0;
          months[month] = income;
          expensesByMonth[month] = expenses;
          savingsByMonth[month] = savings;
          incomeTotal += income;
          expenseTotal += expenses;
          savingsTotal += savings;
        }

        final maximum = <double>[
          ...months,
          ...expensesByMonth,
          ...savingsByMonth,
        ].fold<double>(
          0,
          (maximum, value) => math.max(maximum, value).toDouble(),
        );
        final chartWidth = math
            .max(MediaQuery.sizeOf(context).width - 64, 12 * 40.0)
            .toDouble();
        final chartScale = MediaQuery.textScalerOf(context).scale(10) / 10;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Yearly totals',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  '${widget.year}',
                  maxLines: 1,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _YearTotal(
                  label: 'Income',
                  amount: incomeTotal,
                  symbol: widget.currencySymbol,
                  color: Colors.green,
                ),
                _YearTotal(
                  label: 'Expenses',
                  amount: expenseTotal,
                  symbol: widget.currencySymbol,
                  color: Colors.red,
                ),
                _YearTotal(
                  label: 'Savings',
                  amount: savingsTotal,
                  symbol: widget.currencySymbol,
                  color: Colors.blue,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: const [
                _ChartLegend(label: 'Income', color: Colors.green),
                _ChartLegend(label: 'Expenses', color: Colors.red),
                _ChartLegend(label: 'Savings / Net', color: Colors.blue),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: chartWidth,
                height: 260 * chartScale,
                child: BarChart(
                  BarChartData(
                    maxY: maximum == 0 ? 1 : maximum * 1.15,
                    minY: 0,
                    alignment: BarChartAlignment.spaceAround,
                    gridData: const FlGridData(show: true),
                    borderData: FlBorderData(show: false),
                    barTouchData: BarTouchData(
                      enabled: true,
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          final labels = ['Income', 'Expenses', 'Savings'];
                          return BarTooltipItem(
                            '${labels[rodIndex]}\n${widget.currencySymbol}${NumberFormat('#,##0.##').format(rod.toY)}',
                            const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          );
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 34 * chartScale,
                          getTitlesWidget: (value, meta) {
                            final month = value.toInt();
                            if (month < 1 || month > 12) {
                              return const SizedBox.shrink();
                            }
                            return SideTitleWidget(
                              meta: meta,
                              child: Text(
                                DateFormat.MMM().format(
                                  DateTime(widget.year, month),
                                ),
                                maxLines: 1,
                                style: const TextStyle(fontSize: 10),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    barGroups: List.generate(12, (index) {
                      return BarChartGroupData(
                        x: index + 1,
                        barsSpace: 2,
                        barRods: [
                          BarChartRodData(
                            toY: months[index],
                            color: Colors.green,
                            width: 7,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          BarChartRodData(
                            toY: expensesByMonth[index],
                            color: Colors.red,
                            width: 7,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          BarChartRodData(
                            toY: savingsByMonth[index],
                            color: Colors.blue,
                            width: 7,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _YearTotal extends StatelessWidget {
  final String label;
  final double amount;
  final String symbol;
  final Color color;

  const _YearTotal({
    required this.label,
    required this.amount,
    required this.symbol,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            '$symbol${NumberFormat('#,##0.##').format(amount)}',
            softWrap: true,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _ChartLegend extends StatelessWidget {
  final String label;
  final Color color;

  const _ChartLegend({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 4),
        Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}
