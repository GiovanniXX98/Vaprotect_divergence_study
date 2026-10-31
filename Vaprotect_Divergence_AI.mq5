//+------------------------------------------------------------------+
//|                                     Vaprotect_Divergence_AI.mq5   |
//|                         Copyright 2026, Quantitative AI Study    |
//|                                             https://mql5.com     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Quantitative AI Study"
#property link      ""
#property version   "2.10"
#property description "Vaprotect Statistical Arbitrage & Mean Reversion AI"
#property description "Architettura anti-overfitting con target minimo, break-even dinamico e protezione oraria"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| PARAMETRI DI INPUT                                               |
//+------------------------------------------------------------------+
input group "=== SIMBOLI E VOLUME ==="
input string InpSymbol2              = "GBPUSD";    // Asset Secondario (Coppia correlata)
input double InpLotSize              = 0.05;        // Lottaggio Base Asset Principale
input int    InpMagicNumber          = 77779;       // Magic Number EA

input group "=== PARAMETRI ALGORITMO SPREAD (ROBUSTI & NATURALI) ==="
input int    InpZScorePeriod         = 24;          // Finestra Z-Score Spread (24 ore = 1 giorno naturale)
input double InpBandMin              = 2.50;        // Soglia Z-Score minima di ingresso (|Z| >= 2.50 dev. std.)
input int    InpLookbackBars         = 720;         // Lookback Macro (720 ore = 1 mese di trading)
input double InpPeakZMultiplier      = 0.25;        // % del picco storico Z per filtro adattivo
input int    InpMaFast               = 12;          // Media Mobile Veloce su Spread (12 ore = mezza giornata)
input int    InpMaMed                = 36;          // Media Mobile Media su Spread (36 ore = 1.5 giorni)
input int    InpMaSlow               = 72;          // Media Mobile Lenta su Spread (72 ore = 3 giorni)

input group "=== FILTRI DI CORRELAZIONE E REGIME ==="
input double InpMinCorrelation       = 0.70;        // Correlazione Minima Macro (Lookback 720h)
input double InpMinShortCorr         = 0.50;        // Correlazione Minima Breve Periodo
input int    InpShortCorrBars        = 24;          // Barre correlazione breve (24 ore)
input int    InpCorrPersistHours     = 72;          // Ore persistenza correlazione bassa per Cigno Nero

input group "=== GESTIONE DEL PROFITTO (TARATA SULLA DISTRIBUZIONE REALE) ==="
input double InpMinProfitMoney       = 1.0;         // Profitto Minimo Netto (€) a Z=0 (evita uscite a +0.02€ da micro-tick)
input double InpTargetOvershootZ     = 0.00;        // Overshoot Z (0.0 = esci esattamente al ritorno alla media Z=0)
input bool   InpUseBreakEven         = true;        // Attiva Break-Even Dinamico
input double InpBreakEvenTrigger     = 8.0;         // Profitto (€) che attiva la protezione (tarato su 0.05 lot)
input double InpBreakEvenLock        = 2.0;         // Profitto minimo garantito (€) una volta scattato il Break-Even

input group "=== GESTIONE DEL RISCHIO E STOP LOSS ==="
input double InpStopLossDev          = 4.20;        // Z-Score Stop Loss Strutturale (anomalia estrema)
input double InpMaxLossMoney         = 50.0;        // Hard Stop Loss Monetario (€) globale per basket
input int    InpMaxTradeHours        = 96;          // Time Stop: Ore massime a mercato (96h = 4 giorni di borsa)
input int    InpCooldownHours        = 4;           // Ore di pausa dopo qualsiasi Stop Loss o anomalia

input group "=== FILTRO ORARIO E PROTEZIONE WEEKEND ==="
input bool   InpFilterFriday         = true;        // Evita nuovi ingressi il venerdì sera
input int    InpFridayCutoffHour     = 18;          // Ora blocco ingressi venerdì (broker time)

input group "=== FILTRO NOTIZIE AD ALTO IMPATTO & FLASH CRASH ==="
input bool   InpUseNewsFilter        = false;       // Attiva Protezione Notizie (false nel backtest storico per non bloccare divergenze)
input int    InpMaxSpreadPips        = 5;           // Spread Massimo in pip (blocca allargamenti violenti da news)
input bool   InpUseAtrShockFilter    = false;       // Filtro Volatilità Anomala (se true, blocca ingressi su candele estreme)
input double InpAtrShockMultiplier   = 3.0;         // Moltiplicatore ATR per shock di volatilità
input bool   InpFilterRecurringNews  = false;       // Blocca finestre fisse di news critiche
input bool   InpUseCalendarAPI       = true;        // Calendario Economico Nativo MT5 (attivo solo in Live Trading)
input int    InpNewsMinsBefore       = 45;          // Minuti di blocco PRIMA di notizie ad alto impatto
input int    InpNewsMinsAfter        = 90;          // Minuti di blocco DOPO notizie ad alto impatto
input bool   InpCloseBeforeNews      = false;       // Chiudi posizioni aperte prima di news (false = solo blocca nuovi ingressi)

//+------------------------------------------------------------------+
//| VARIABILI GLOBALI                                                |
//+------------------------------------------------------------------+
CTrade   trade;
double   last_zscore         = 0.0;
bool     first_tick          = true;
datetime cooldown_until      = 0;
datetime corr_low_since      = 0;     
datetime position_open_time  = 0;
bool     breakeven_activated = false;
double   max_favorable_profit= 0.0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(InpMagicNumber);

  if (!MQLInfoInteger(MQL_TESTER)) {
    trade.SetAsyncMode(true);
  }

  if (!SymbolSelect(InpSymbol2, true)) {
    Print("Errore: Impossibile selezionare il simbolo secondario ", InpSymbol2);
    return (INIT_FAILED);
  }

  Print("Vaprotect Divergence AI inizializzato con successo. Simbolo1: ", _Symbol, " | Simbolo2: ", InpSymbol2);
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  Print("Vaprotect Divergence AI arrestato. Motivo: ", reason);
}

//+------------------------------------------------------------------+
//| Calcolo Coefficiente di Correlazione di Pearson                  |
//+------------------------------------------------------------------+
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
    num  += diff1 * diff2;
    den1 += diff1 * diff1;
    den2 += diff2 * diff2;
  }
  if (den1 * den2 <= 0.000000001) return 0.0;
  return num / MathSqrt(den1 * den2);
}

//+------------------------------------------------------------------+
//| Verifica se il mercato è aperto per entrambi i simboli           |
//+------------------------------------------------------------------+
bool IsTradeAllowedNow() {
  MqlDateTime dt;
  TimeToStruct(TimeCurrent(), dt);

  // Blocco venerdì sera dopo cutoff per evitare gap di apertura e spread notturni
  if (InpFilterFriday && dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour) {
    return false;
  }
  // Blocco weekend
  if (dt.day_of_week == 6 || (dt.day_of_week == 0 && dt.hour < 22)) {
    return false;
  }

  long mode1 = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
  long mode2 = SymbolInfoInteger(InpSymbol2, SYMBOL_TRADE_MODE);
  if (mode1 != SYMBOL_TRADE_MODE_FULL || mode2 != SYMBOL_TRADE_MODE_FULL) {
    return false;
  }

  return true;
}

//+------------------------------------------------------------------+
//| Rilevamento Notizie ad Alto Impatto, Allargamento Spread & Crash |
//+------------------------------------------------------------------+
bool IsNewsOrShockActive(string &reason) {
  if (!InpUseNewsFilter) return false;

  // 1. FILTRO SPREAD ANOMALO (Durante le news lo spread si allarga di 3x-10x)
  double point1 = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  double point2 = SymbolInfoDouble(InpSymbol2, SYMBOL_POINT);
  int digits1   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  int digits2   = (int)SymbolInfoInteger(InpSymbol2, SYMBOL_DIGITS);
  double pip1   = (digits1 == 3 || digits1 == 5) ? point1 * 10.0 : point1;
  double pip2   = (digits2 == 3 || digits2 == 5) ? point2 * 10.0 : point2;

  long spr1 = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  long spr2 = SymbolInfoInteger(InpSymbol2, SYMBOL_SPREAD);
  double spread_pips1 = (pip1 > 0) ? (spr1 * point1 / pip1) : 0.0;
  double spread_pips2 = (pip2 > 0) ? (spr2 * point2 / pip2) : 0.0;

  if (spread_pips1 > InpMaxSpreadPips || spread_pips2 > InpMaxSpreadPips) {
    reason = StringFormat("Spread allargato da news/illiquidita (%s: %.1f pip, %s: %.1f pip)", _Symbol, spread_pips1, InpSymbol2, spread_pips2);
    return true;
  }

  // 2. FILTRO SHOCK DI VOLATILITA / FLASH CRASH (ATR Spike Detector)
  if (InpUseAtrShockFilter) {
    double h1[], l1[], c1[];
    ArraySetAsSeries(h1, true);
    ArraySetAsSeries(l1, true);
    ArraySetAsSeries(c1, true);
    if (CopyHigh(_Symbol, PERIOD_CURRENT, 0, 16, h1) >= 16 &&
        CopyLow(_Symbol, PERIOD_CURRENT, 0, 16, l1) >= 16 &&
        CopyClose(_Symbol, PERIOD_CURRENT, 0, 16, c1) >= 16) {
      double tr_sum = 0.0;
      for (int k = 1; k <= 14; k++) {
        double tr = MathMax(h1[k] - l1[k], MathMax(MathAbs(h1[k] - c1[k + 1]), MathAbs(l1[k] - c1[k + 1])));
        tr_sum += tr;
      }
      double atr1 = tr_sum / 14.0;
      double bar_range1 = h1[0] - l1[0];
      if (atr1 > 0.00001 && bar_range1 > atr1 * InpAtrShockMultiplier) {
        reason = StringFormat("Shock di volatilita su %s (Range barra %.1f pips > %.1fx ATR)", _Symbol, bar_range1 / (pip1 > 0 ? pip1 : 0.0001), InpAtrShockMultiplier);
        return true;
      }
    }

    double h2[], l2[], c2[];
    ArraySetAsSeries(h2, true);
    ArraySetAsSeries(l2, true);
    ArraySetAsSeries(c2, true);
    if (CopyHigh(InpSymbol2, PERIOD_CURRENT, 0, 16, h2) >= 16 &&
        CopyLow(InpSymbol2, PERIOD_CURRENT, 0, 16, l2) >= 16 &&
        CopyClose(InpSymbol2, PERIOD_CURRENT, 0, 16, c2) >= 16) {
      double tr_sum = 0.0;
      for (int k = 1; k <= 14; k++) {
        double tr = MathMax(h2[k] - l2[k], MathMax(MathAbs(h2[k] - c2[k + 1]), MathAbs(l2[k] - c2[k + 1])));
        tr_sum += tr;
      }
      double atr2 = tr_sum / 14.0;
      double bar_range2 = h2[0] - l2[0];
      if (atr2 > 0.00001 && bar_range2 > atr2 * InpAtrShockMultiplier) {
        reason = StringFormat("Shock di volatilita su %s (Range barra %.1f pips > %.1fx ATR)", InpSymbol2, bar_range2 / (pip2 > 0 ? pip2 : 0.0001), InpAtrShockMultiplier);
        return true;
      }
    }
  }

  // 3. FINESTRE ORARIE NOTIZIE PERIODICHE AD ALTO IMPATTO
  if (InpFilterRecurringNews) {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    
    // NFP USA (Primo venerdi del mese tra le 12:00 e le 16:00 broker time)
    if (dt.day_of_week == 5 && dt.day <= 7 && dt.hour >= 12 && dt.hour <= 16) {
      reason = "Finestra ad alto impatto: NFP (Non-Farm Payrolls USA)";
      return true;
    }
    // Giovedi tassi d'interesse BCE / BoE (ore 12:00-15:30 broker time)
    if (dt.day_of_week == 4 && dt.day <= 14 && dt.hour >= 12 && dt.hour <= 15) {
      reason = "Finestra ad alto impatto: Meeting BCE / BoE tassi";
      return true;
    }
  }

  // 4. CALENDARIO ECONOMICO NATIVO MT5 (Attivo in Live Trading)
  if (InpUseCalendarAPI && !MQLInfoInteger(MQL_TESTER)) {
    datetime now = TimeCurrent();
    datetime from = now - InpNewsMinsAfter * 60;
    datetime to   = now + InpNewsMinsBefore * 60;
    
    MqlCalendarValue values[];
    string countries[3] = {"US", "EU", "GB"};
    for (int c = 0; c < 3; c++) {
      int count = CalendarValueHistory(values, from, to, countries[c]);
      for (int v = 0; v < count; v++) {
        MqlCalendarEvent event;
        if (CalendarEventById(values[v].event_id, event)) {
          if (event.importance == CALENDAR_IMPORTANCE_HIGH) {
            reason = StringFormat("Notizia Macro %s (%s)", event.name, countries[c]);
            return true;
          }
        }
      }
    }
  }

  return false;
}

//+------------------------------------------------------------------+
//| Chiusura sicura di tutte le posizioni con magic number           |
//+------------------------------------------------------------------+
bool CloseAllOurPositions() {
  int total = PositionsTotal();
  bool all_closed = true;

  for (int i = total - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
      if (!trade.PositionClose(ticket)) {
        all_closed = false;
      }
    }
  }

  if (all_closed) {
    position_open_time   = 0;
    breakeven_activated  = false;
    max_favorable_profit = 0.0;
    corr_low_since       = 0;
  }
  return all_closed;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
  int calc_period = MathMax(InpZScorePeriod, InpMaSlow);
  int total_bars_needed = calc_period * 2;

  double close1[], close2[];
  ArraySetAsSeries(close1, true);
  ArraySetAsSeries(close2, true);

  if (CopyClose(_Symbol, PERIOD_CURRENT, 0, total_bars_needed, close1) < total_bars_needed) return;
  if (CopyClose(InpSymbol2, PERIOD_CURRENT, 0, total_bars_needed, close2) < total_bars_needed) return;

  // Calcolo spread percentuale normalizzato
  double spread_array[];
  ArrayResize(spread_array, calc_period);

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
  }

  // Media e Deviazione Standard dello spread
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

  // Medie mobili per conferma pendenza (Slope / Momentum)
  double ma_fast = 0.0, ma_med = 0.0, ma_slow = 0.0;
  for (int k = 0; k < InpMaFast; k++) ma_fast += spread_array[k];
  ma_fast /= InpMaFast;
  for (int k = 0; k < InpMaMed; k++) ma_med += spread_array[k];
  ma_med /= InpMaMed;
  for (int k = 0; k < InpMaSlow; k++) ma_slow += spread_array[k];
  ma_slow /= InpMaSlow;

  // Stima del picco Z storico adattivo
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
      double mean_macro = sum_s / InpLookbackBars;
      double sum_sq_macro = 0.0;
      for (int i = 0; i < InpLookbackBars; i++) sum_sq_macro += MathPow(spreads[i] - mean_macro, 2.0);
      double std_macro = MathSqrt(sum_sq_macro / InpLookbackBars);
      double max_z = 0.0;
      for (int i = 0; i < InpLookbackBars; i++) {
        if (std_dev > 0.000001) {
          double zz = MathAbs(spreads[i] - mean_spread) / std_dev;
          if (std_macro > 0.000001 && MathAbs(spreads[i] - mean_macro) / std_macro > 3.0) continue;
          if (zz > max_z) max_z = zz;
        }
      }
      if (max_z > 0.0) peak_z = max_z;
    }
  }

  // --- RILEVAMENTO POSIZIONI APERTE ---
  int open_positions = PositionsTotal();
  bool has_our_positions = false;
  int our_positions_count = 0;
  int trade_direction = 0; // +1 = Long Spread (Buy Sym1, Sell Sym2) | -1 = Short Spread (Sell Sym1, Buy Sym2)

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

  // Protezione gamba orfana (se solo 1 trade è aperto su 2 previsti)
  if (our_positions_count == 1 || (our_positions_count > 0 && our_positions_count % 2 != 0)) {
    Print("ATTENZIONE: Rilevata posizione orfana/scoperta! Chiusura immediata di emergenza.");
    CloseAllOurPositions();
    cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    last_zscore = current_zscore; 
    return; 
  }

  //+------------------------------------------------------------------+
  //| GESTIONE DELLE POSIZIONI APERTE (USCITA & RISK MANAGEMENT)       |
  //+------------------------------------------------------------------+
  if (has_our_positions) {
    double total_net_profit = 0.0;
    for (int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
        total_net_profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
      }
    }

    if (total_net_profit > max_favorable_profit) {
      max_favorable_profit = total_net_profit;
    }

    // Attivazione Break-Even
    if (InpUseBreakEven && !breakeven_activated && total_net_profit >= InpBreakEvenTrigger) {
      breakeven_activated = true;
      Print("BREAK-EVEN ATTIVATO: Profitto ha toccato ", total_net_profit, " EUR. Soglia minima garantita: ", InpBreakEvenLock, " EUR.");
    }

    double current_short_corr = 0.0;
    double temp_h1[], temp_h2[];
    ArraySetAsSeries(temp_h1, true);
    ArraySetAsSeries(temp_h2, true);
    if (CopyClose(_Symbol, PERIOD_CURRENT, 0, InpShortCorrBars, temp_h1) >= InpShortCorrBars &&
        CopyClose(InpSymbol2, PERIOD_CURRENT, 0, InpShortCorrBars, temp_h2) >= InpShortCorrBars) {
      current_short_corr = CalculateCorrelation(temp_h1, temp_h2, InpShortCorrBars);
    }

    double duration_h = 0.0;
    if (position_open_time > 0) {
      duration_h = (double)(TimeCurrent() - position_open_time) / 3600.0;
    }

    bool close_all = false;
    string exit_reason = "";

    // 1. HARD STOP LOSS MONETARIO GLOBALE
    if (InpMaxLossMoney > 0.0 && total_net_profit <= -InpMaxLossMoney) {
      close_all = true;
      exit_reason = "EXIT_HARD_STOP";
      cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    }
    // 2. STOP LOSS STRUTTURALE Z-SCORE
    else if (MathAbs(current_zscore) > InpStopLossDev) {
      close_all = true;
      exit_reason = "EXIT_Z_SCORE_SL";
      cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    }
    // 3. PROTEZIONE BREAK-EVEN DINAMICO (Previene che un gain da +25€ finisca in Hard Stop)
    else if (InpUseBreakEven && breakeven_activated && total_net_profit <= InpBreakEvenLock) {
      close_all = true;
      exit_reason = "EXIT_BREAK_EVEN";
    }
    // 4. FILTRO CIGNO NERO (Collasso persistente della correlazione a breve termine)
    else if (current_short_corr > 0.0 && current_short_corr < InpMinShortCorr) {
      if (corr_low_since == 0) corr_low_since = TimeCurrent(); 
      int hours_low = (int)((TimeCurrent() - corr_low_since) / 3600);
      if (hours_low >= InpCorrPersistHours) {
        close_all = true;
        exit_reason = "EXIT_CIGNO_NERO";
        cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
      }
    } else {
      if (corr_low_since != 0) corr_low_since = 0;
    }

    // 5. TIME STOP (Chiudi se a mercato da troppi giorni senza convergenza)
    if (!close_all && InpMaxTradeHours > 0 && duration_h >= InpMaxTradeHours) {
      if (total_net_profit >= 0.0 || total_net_profit > -InpMaxLossMoney * 0.5) {
        close_all = true;
        exit_reason = "EXIT_TIME_STOP";
        cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
      }
    }

    // 6. TARGET MEAN REVERSION OTTIMIZZATO (Elimina le uscite a +0.02€)
    if (!close_all) {
      bool mean_crossed = false;
      // Target raggiunto con leggero overshoot verso segno opposto per catturare il pieno momentum
      if (trade_direction == -1 && current_zscore <= -InpTargetOvershootZ) mean_crossed = true;
      else if (trade_direction == 1 && current_zscore >= InpTargetOvershootZ) mean_crossed = true;

      if (mean_crossed) {
        // Esce non appena lo Z-Score torna a 0 e il profitto netto copre i costi (>= InpMinProfitMoney)
        if (total_net_profit >= InpMinProfitMoney || (InpMinProfitMoney <= 0.0 && total_net_profit > 0.0)) {
          close_all = true;
          exit_reason = "EXIT_TARGET_PROFIT";
        }
      }
    }

    // 7. PROTEZIONE NOTIZIE AD ALTO IMPATTO (Opzionale: chiusura preventiva prima delle news)
    if (!close_all && InpCloseBeforeNews) {
      string news_r = "";
      if (IsNewsOrShockActive(news_r)) {
        close_all = true;
        exit_reason = "EXIT_NEWS_PROTECTION";
        Print("CHIUSURA PREVENTIVA NOTIZIA: ", news_r);
        cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
      }
    }

    // ESECUZIONE DELLA CHIUSURA
    if (close_all) {
      // Controlla che il mercato sia operativo prima di tentare la chiusura
      long mode1 = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
      long mode2 = SymbolInfoInteger(InpSymbol2, SYMBOL_TRADE_MODE);
      if (mode1 == SYMBOL_TRADE_MODE_FULL && mode2 == SYMBOL_TRADE_MODE_FULL) {
        Print(exit_reason, " | PnL: ", total_net_profit, " | Z: ", current_zscore, " | Ore: ", duration_h);
        CloseAllOurPositions();
      }
    }
  }

  //+------------------------------------------------------------------+
  //| VERIFICA SEGNALI DI INGRESSO (SE NON CI SONO POSIZIONI ATTIVE)   |
  //+------------------------------------------------------------------+
  if (!has_our_positions) {
    if (TimeCurrent() < cooldown_until) return;
    if (!IsTradeAllowedNow()) return;

    // Filtro Notizie Macro, Allargamento Spread e Flash Crash
    string news_r = "";
    if (IsNewsOrShockActive(news_r)) {
      return; // Congela ed evita qualsiasi nuovo ingresso durante shock o news
    }

    double dynamic_band = peak_z * InpPeakZMultiplier;
    double entry_band = MathMax(dynamic_band, InpBandMin);

    bool in_zone_high = (current_zscore > entry_band);
    bool in_zone_low  = (current_zscore < -entry_band);

    // Conferma di inversione pendenza dello spread tramite Medie Mobili
    bool trigger_short = in_zone_high && (ma_fast < ma_med && ma_med < ma_slow);
    bool trigger_long  = in_zone_low  && (ma_fast > ma_med && ma_med > ma_slow);

    if (trigger_short || trigger_long) {
      double corr = 0.0;
      double short_corr = 0.0;
      double h1[], h2[];
      ArraySetAsSeries(h1, true);
      ArraySetAsSeries(h2, true);

      if (CopyClose(_Symbol, PERIOD_CURRENT, 0, InpLookbackBars, h1) >= InpLookbackBars &&
          CopyClose(InpSymbol2, PERIOD_CURRENT, 0, InpLookbackBars, h2) >= InpLookbackBars) {
        corr = CalculateCorrelation(h1, h2, InpLookbackBars);
        short_corr = CalculateCorrelation(h1, h2, InpShortCorrBars);
      }

      // Filtro Correlazione Macro e Micro
      if (corr >= InpMinCorrelation && short_corr >= InpMinShortCorr) {
        
        // Calcolo Volumi Bilanciati sul Valore del Tick
        double tick_val1 = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_val2 = SymbolInfoDouble(InpSymbol2, SYMBOL_TRADE_TICK_VALUE);
        double tick_size1 = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double tick_size2 = SymbolInfoDouble(InpSymbol2, SYMBOL_TRADE_TICK_SIZE);
        
        double raw_lot2 = InpLotSize;
        if (tick_val1 > 0 && tick_val2 > 0 && tick_size1 > 0 && tick_size2 > 0) {
          raw_lot2 = InpLotSize * (current_price1 * tick_val1 * tick_size2) / (current_price2 * tick_val2 * tick_size1);
        } else {
          raw_lot2 = InpLotSize * (current_price1 / current_price2);
        }
        
        double lot_step2 = SymbolInfoDouble(InpSymbol2, SYMBOL_VOLUME_STEP);
        if (lot_step2 <= 0.0) lot_step2 = 0.01;
        double min_lot2  = SymbolInfoDouble(InpSymbol2, SYMBOL_VOLUME_MIN);
        
        double lot_size2 = MathRound(raw_lot2 / lot_step2) * lot_step2;
        lot_size2 = NormalizeDouble(lot_size2, 2);
        if (lot_size2 < min_lot2) lot_size2 = min_lot2;

        double margin1 = 0, margin2 = 0;
        if (!OrderCalcMargin(trigger_long ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, InpLotSize, current_price1, margin1)) margin1 = 1000;
        if (!OrderCalcMargin(trigger_long ? ORDER_TYPE_SELL : ORDER_TYPE_BUY, InpSymbol2, lot_size2, current_price2, margin2)) margin2 = 1000;

        if (AccountInfoDouble(ACCOUNT_MARGIN_FREE) < (margin1 + margin2) * 1.5) {
          cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
        } else {
          // Apertura simultanea delle due gambe
          if (trigger_short) {
            if (trade.Sell(InpLotSize, _Symbol)) {
              if (!trade.Buy(lot_size2, InpSymbol2)) {
                trade.PositionClose(_Symbol); // Protezione orfana immediata
                cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
              } else {
                position_open_time   = TimeCurrent();
                breakeven_activated  = false;
                max_favorable_profit = 0.0;
              }
            }
          } else if (trigger_long) {
            if (trade.Buy(InpLotSize, _Symbol)) {
              if (!trade.Sell(lot_size2, InpSymbol2)) {
                trade.PositionClose(_Symbol); // Protezione orfana immediata
                cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
              } else {
                position_open_time   = TimeCurrent();
                breakeven_activated  = false;
                max_favorable_profit = 0.0;
              }
            }
          }
        }
      }
    }
  }

  last_zscore = current_zscore;
}
//+------------------------------------------------------------------+
