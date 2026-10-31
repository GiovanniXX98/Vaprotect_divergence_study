//+------------------------------------------------------------------+
//|                             Vaprotect_Divergence_Corretto.mq5    |
//|                                      Copyright 2026              |
//|                                             https://mql5.com     |
//+------------------------------------------------------------------+
#property copyright "2026"
#property link ""
#property version "1.10"

#include <Trade\Trade.mqh>

input string InpSymbol2 = "GBPUSD";    // Asset Secondario
input double InpLotSize = 0.05;        // Lottaggio Base
input int InpZScorePeriod = 23;        // Periodi per Z-Score Spread
input double InpStopLossDev = 4.5;     // Z-Score Stop Loss strutturale
input double InpMinCorrelation = 0.70; // Correlazione Minima mensile
input double InpMinShortCorr = 0.50;   // Correlazione Minima breve periodo
input int InpShortCorrBars = 17;       // Barre correlazione breve
input int InpLookbackBars = 1429;      // Finestra storica picco Z
input double InpPeakZMultiplier = 0.23; // % del picco Z per banda ingresso
input double InpBandMin = 2.54;         // Banda ingresso minima assoluta
input int InpMaFast = 17;       // Periodi Media Mobile Veloce su Spread
input int InpMaMed = 45;        // Periodi Media Mobile Intermedia su Spread
input int InpMaSlow = 111;      // Periodi Media Mobile Lenta su Spread
input double InpMaxLossMoney = 50.0; // Hard Stop Loss monetario globale (€/$)
input int InpCooldownHours = 4;      // Ore pausa dopo chiusura
input int InpCorrPersistHours = 72; // Ore min correlazione bassa per Cigno Nero
input bool InpWaitProfitAtTarget = true; // VERO: A target (Z=0) esci SOLO in profitto
input int InpMagicNumber = 77777;   // Magic Number EA

CTrade trade;
double last_zscore = 0.0;
bool first_tick = true;
datetime cooldown_until = 0;
datetime corr_low_since = 0;     
datetime position_open_time = 0; 

int OnInit() {
  trade.SetExpertMagicNumber(InpMagicNumber);

  if (!MQLInfoInteger(MQL_TESTER)) {
    trade.SetAsyncMode(true);
  }

  if (!SymbolSelect(InpSymbol2, true)) {
    Print("Errore: Impossibile selezionare il simbolo ", InpSymbol2);
    return (INIT_FAILED);
  }

  return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {}

double CalculateCorrelation(const double &arr1[], const double &arr2[], int count) {
  if (count <= 1) return 0.0;
  double sum1 = 0.0, sum2 = 0.0;
  for (int i = 0; i < count; i++) {
    sum1 += arr1[i];
    sum2 += arr2[i];
  }
  double mean1 = sum1 / count;
  double mean2 = sum2 / count;
  double num = 0.0, den1 = 0.0, den2 = 0.0;
  for (int i = 0; i < count; i++) {
    double diff1 = arr1[i] - mean1;
    double diff2 = arr2[i] - mean2;
    num += diff1 * diff2;
    den1 += diff1 * diff1;
    den2 += diff2 * diff2;
  }
  if (den1 * den2 == 0.0) return 0.0;
  return num / MathSqrt(den1 * den2);
}

void OnTick() {
  int calc_period = MathMax(InpZScorePeriod, InpMaSlow);
  int total_bars_needed = calc_period * 2;

  double close1[], close2[];
  ArraySetAsSeries(close1, true);
  ArraySetAsSeries(close2, true);

  if (CopyClose(_Symbol, PERIOD_CURRENT, 0, total_bars_needed, close1) < total_bars_needed) return;
  if (CopyClose(InpSymbol2, PERIOD_CURRENT, 0, total_bars_needed, close2) < total_bars_needed) return;

  double spread_array[];
  ArrayResize(spread_array, calc_period);
  double sum_spread = 0.0;

  for (int i = 0; i < calc_period; i++) {
    double sum1 = 0.0, sum2 = 0.0;
    for (int j = 0; j < calc_period; j++) {
      sum1 += close1[i + j];
      sum2 += close2[i + j];
    }
    double ma1 = sum1 / calc_period;
    double ma2 = sum2 / calc_period;

    double dev1 = 0.0, dev2 = 0.0;
    if (ma1 > 0.000001) dev1 = (close1[i] - ma1) / ma1 * 100.0;
    if (ma2 > 0.000001) dev2 = (close2[i] - ma2) / ma2 * 100.0;

    spread_array[i] = dev1 - dev2;
    sum_spread += spread_array[i];
  }

  double sum_z_spread = 0.0;
  for (int i = 0; i < InpZScorePeriod; i++) sum_z_spread += spread_array[i];
  double mean_spread = sum_z_spread / InpZScorePeriod;

  double sum_sq_diff = 0.0;
  for (int i = 0; i < InpZScorePeriod; i++) sum_sq_diff += MathPow(spread_array[i] - mean_spread, 2.0);
  double std_dev = MathSqrt(sum_sq_diff / InpZScorePeriod);

  double current_price1 = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double current_price2 = SymbolInfoDouble(InpSymbol2, SYMBOL_BID);

  double current_spread = spread_array[0];
  double current_zscore = 0.0;
  if (std_dev > 0.000001) current_zscore = (current_spread - mean_spread) / std_dev;

  if (first_tick) {
    last_zscore = current_zscore;
    first_tick = false;
    return;
  }

  if (TimeCurrent() < cooldown_until) return;

  double ma_fast = 0.0, ma_med = 0.0, ma_slow = 0.0;
  for (int k = 0; k < InpMaFast; k++) ma_fast += spread_array[k];
  ma_fast /= InpMaFast;
  for (int k = 0; k < InpMaMed; k++) ma_med += spread_array[k];
  ma_med /= InpMaMed;
  for (int k = 0; k < InpMaSlow; k++) ma_slow += spread_array[k];
  ma_slow /= InpMaSlow;

  double peak_z = 2.0; 
  {
    int peak_bars_needed = InpLookbackBars + InpZScorePeriod;
    double hist1[], hist2[];
    ArraySetAsSeries(hist1, true);
    ArraySetAsSeries(hist2, true);
    if (CopyClose(_Symbol, PERIOD_CURRENT, 0, peak_bars_needed, hist1) >= peak_bars_needed &&
        CopyClose(InpSymbol2, PERIOD_CURRENT, 0, peak_bars_needed, hist2) >= peak_bars_needed) {
      double sum_s = 0.0;
      double spreads[];
      ArrayResize(spreads, InpLookbackBars);

      for (int i = 0; i < InpLookbackBars; i++) {
        double sum1 = 0.0, sum2 = 0.0;
        for (int j = 0; j < InpZScorePeriod; j++) {
          sum1 += hist1[i + j];
          sum2 += hist2[i + j];
        }
        double ma1 = sum1 / InpZScorePeriod;
        double ma2 = sum2 / InpZScorePeriod;
        double dev1 = 0.0, dev2 = 0.0;
        if (ma1 > 0.000001) dev1 = (hist1[i] - ma1) / ma1 * 100.0;
        if (ma2 > 0.000001) dev2 = (hist2[i] - ma2) / ma2 * 100.0;
        spreads[i] = dev1 - dev2;
        sum_s += spreads[i];
      }
      double mean_720 = sum_s / InpLookbackBars;
      double sum_sq_720 = 0.0;
      for (int i = 0; i < InpLookbackBars; i++) sum_sq_720 += MathPow(spreads[i] - mean_720, 2.0);
      double std_720 = MathSqrt(sum_sq_720 / InpLookbackBars);
      double max_z = 0.0;
      for (int i = 0; i < InpLookbackBars; i++) {
        if (std_dev > 0.000001) {
          double zz = MathAbs(spreads[i] - mean_spread) / std_dev;
          if (std_720 > 0.000001 && MathAbs(spreads[i] - mean_720) / std_720 > 3.0) continue;
          if (zz > max_z) max_z = zz;
        }
      }
      if (max_z > 0.0) peak_z = max_z;
    }
  }

  int open_positions = PositionsTotal();
  bool has_our_positions = false;
  int our_positions_count = 0;
  int trade_direction = 0; 

  for (int i = 0; i < open_positions; i++) {
    ulong ticket = PositionGetTicket(i);
    if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
      has_our_positions = true;
      our_positions_count++;
      if (PositionGetString(POSITION_SYMBOL) == _Symbol) {
        if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) trade_direction = 1;
        else if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) trade_direction = -1;
      }
    }
  }

  if (our_positions_count == 1 || (our_positions_count > 0 && our_positions_count % 2 != 0)) {
    Print("ATTENZIONE: Rilevata posizione orfana/scoperta! Chiusura immediata e COOLDOWN.");
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) trade.PositionClose(ticket);
    }
    cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    last_zscore = current_zscore; 
    return; 
  }

  if (has_our_positions) {
    double total_net_profit = 0.0;
    for (int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
        total_net_profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
      }
    }

    bool close_all = false;
    double current_short_corr = 0.0;
    double temp_h1[], temp_h2[];
    ArraySetAsSeries(temp_h1, true);
    ArraySetAsSeries(temp_h2, true);
    if (CopyClose(_Symbol, PERIOD_CURRENT, 0, InpShortCorrBars, temp_h1) >= InpShortCorrBars &&
        CopyClose(InpSymbol2, PERIOD_CURRENT, 0, InpShortCorrBars, temp_h2) >= InpShortCorrBars) {
      current_short_corr = CalculateCorrelation(temp_h1, temp_h2, InpShortCorrBars);
    }
    double duration_h = (double)(TimeCurrent() - position_open_time) / 3600.0;

    if (InpMaxLossMoney > 0.0 && total_net_profit <= -InpMaxLossMoney) {
      close_all = true;
      corr_low_since = 0; 
      Print("EXIT_HARD_STOP | PnL: ", total_net_profit, " | Z: ", current_zscore, " | Ore: ", duration_h);
      cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    }
    else if (current_short_corr > 0.0 && current_short_corr < InpMinShortCorr) {
      if (corr_low_since == 0) corr_low_since = TimeCurrent(); 
      int hours_low = (int)((TimeCurrent() - corr_low_since) / 3600);
      if (InpCorrPersistHours == 0 || hours_low >= InpCorrPersistHours) {
        close_all = true;
        corr_low_since = 0;
        Print("EXIT_CIGNO_NERO | PnL: ", total_net_profit, " | Z: ", current_zscore, " | Ore: ", duration_h);
        cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
      }
    } else {
      if (corr_low_since != 0) corr_low_since = 0;
    }

    if (!close_all && MathAbs(current_zscore) > InpStopLossDev) {
      close_all = true;
      corr_low_since = 0;
      Print("EXIT_Z_SCORE_SL | PnL: ", total_net_profit, " | Z: ", current_zscore, " | Ore: ", duration_h);
      cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    }

    // --- LOGICA TARGET MIGLIORATA ---
    if (!close_all) {
      bool target_reached = false;
      if (trade_direction == -1 && current_zscore <= 0.0) target_reached = true;
      else if (trade_direction == 1 && current_zscore >= 0.0) target_reached = true;

      if (target_reached) {
        if (!InpWaitProfitAtTarget || total_net_profit > 0) {
          close_all = true;
          Print("EXIT_TARGET_PROFIT | PnL: ", total_net_profit, " | Z: ", current_zscore, " | Ore: ", duration_h);
        } else {
           // Siamo a Target (Z=0) ma PnL è negativo e InpWaitProfitAtTarget è true. Non usciamo ancora!
           // O aspetterà che diventi positivo o chiuderà per Stop Loss.
        }
      }
    }

    if (close_all) {
      position_open_time = 0;
      for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) trade.PositionClose(ticket);
      }
    }
  }
  
  if (!has_our_positions) {
    double entry_band = peak_z * InpPeakZMultiplier;
    if (entry_band < InpBandMin) entry_band = InpBandMin;

    bool in_zone_high = (current_zscore > entry_band);
    bool in_zone_low = (current_zscore < -entry_band);

    bool trigger_short = in_zone_high && (ma_fast < ma_med && ma_med < ma_slow);
    bool trigger_long = in_zone_low && (ma_fast > ma_med && ma_med > ma_slow);

    if (trigger_short || trigger_long) {
      double corr = 0.0;
      double h1[], h2[];
      ArraySetAsSeries(h1, true);
      ArraySetAsSeries(h2, true);
      double short_corr = 0.0;
      if (CopyClose(_Symbol, PERIOD_CURRENT, 0, InpLookbackBars, h1) >= InpLookbackBars &&
          CopyClose(InpSymbol2, PERIOD_CURRENT, 0, InpLookbackBars, h2) >= InpLookbackBars) {
        corr = CalculateCorrelation(h1, h2, InpLookbackBars);
        short_corr = CalculateCorrelation(h1, h2, InpShortCorrBars);
      }

      if (corr >= InpMinCorrelation && short_corr >= InpMinShortCorr) {
        
        // --- BILANCIAMENTO VOLUMI MIGLIORATO BASATO SUL TICK VALUE ---
        double tick_val1 = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_val2 = SymbolInfoDouble(InpSymbol2, SYMBOL_TRADE_TICK_VALUE);
        double tick_size1 = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double tick_size2 = SymbolInfoDouble(InpSymbol2, SYMBOL_TRADE_TICK_SIZE);
        
        // Formula per bilanciare il valore di un movimento dell'1%
        double raw_lot2 = InpLotSize;
        if (tick_val1 > 0 && tick_val2 > 0 && tick_size1 > 0 && tick_size2 > 0) {
            raw_lot2 = InpLotSize * (current_price1 * tick_val1 * tick_size2) / (current_price2 * tick_val2 * tick_size1);
        } else {
            // Fallback
            raw_lot2 = InpLotSize * (current_price1 / current_price2);
        }
        
        double lot_step2 = SymbolInfoDouble(InpSymbol2, SYMBOL_VOLUME_STEP);
        if (lot_step2 <= 0.0) lot_step2 = 0.01;
        double min_lot2 = SymbolInfoDouble(InpSymbol2, SYMBOL_VOLUME_MIN);
        
        double lot_size2 = MathRound(raw_lot2 / lot_step2) * lot_step2;
        lot_size2 = NormalizeDouble(lot_size2, 2);
        if (lot_size2 < min_lot2) lot_size2 = min_lot2;

        double margin1 = 0, margin2 = 0;
        if (!OrderCalcMargin(trigger_long ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, InpLotSize, current_price1, margin1)) margin1 = 1000;
        if (!OrderCalcMargin(trigger_long ? ORDER_TYPE_SELL : ORDER_TYPE_BUY, InpSymbol2, lot_size2, current_price2, margin2)) margin2 = 1000;

        if (AccountInfoDouble(ACCOUNT_MARGIN_FREE) < (margin1 + margin2) * 1.5) {
          cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
        } else {
          if (trigger_short) {
            if (trade.Sell(InpLotSize, _Symbol)) {
              if (!trade.Buy(lot_size2, InpSymbol2)) {
                trade.PositionClose(_Symbol);
                cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
              } else {
                position_open_time = TimeCurrent();
              }
            }
          } else if (trigger_long) {
            if (trade.Buy(InpLotSize, _Symbol)) {
              if (!trade.Sell(lot_size2, InpSymbol2)) {
                trade.PositionClose(_Symbol);
                cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
              } else {
                position_open_time = TimeCurrent();
              }
            }
          }
        }
      }
    }
  }

  last_zscore = current_zscore;
}
