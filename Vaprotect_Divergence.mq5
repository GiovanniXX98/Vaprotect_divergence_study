//+------------------------------------------------------------------+
//|                                       Vaprotect_Divergence.mq5   |
//|                                      Copyright 2026             |
//|                                             https://mql5.com     |
//+------------------------------------------------------------------+
#property copyright "2026"
#property link ""
#property version "1.00"

#include <Trade\Trade.mqh>

input string InpSymbol2 = "GBPUSD";    // Asset Secondario
input double InpLotSize = 0.05;        // Lottaggio (0.05 con leva 1:25)
input int InpZScorePeriod = 50;        // Periodi per Z-Score Spread
input double InpStopLossDev = 4.5;     // Z-Score Stop Loss strutturale
input double InpMinCorrelation = 0.70; // Correlazione Minima mensile
input double InpMinShortCorr = 0.50;   // Correlazione Minima breve periodo
input int InpShortCorrBars = 24;       // Barre correlazione breve
input int InpLookbackBars = 720;       // Finestra storica (H1=720 = 1 mese)
input double InpPeakZMultiplier =
    0.2; // % del picco Z per banda ingresso (0.45 ottimale)
input double InpBandMin = 1.5;  // Banda ingresso minima assoluta
input int InpSlopeWindow = 10;  // Finestra slope (barre)
input int InpSlopeMinHours = 3; // Ore minime aperto prima di uscire su slope
input double InpMaxLossMoney = 50.0; // Hard Stop Loss monetario (€)
input int InpCooldownHours = 4;      // Ore pausa dopo chiusura
input int InpCorrPersistHours = 72; // Ore min correlazione bassa per Cigno Nero
input int InpMagicNumber = 77777;   // Magic Number EA

CTrade trade;
double last_zscore = 0.0;
bool first_tick = true;
datetime cooldown_until = 0;
datetime corr_low_since = 0;     // Timestamp da quando corr24 è sotto soglia
datetime position_open_time = 0; // Timestamp apertura posizione corrente
double slope_sign_at_entry =
    0.0; // Segno slope al momento dell'entrata (+1 o -1)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(InpMagicNumber);

  // ATTIVAZIONE ESECUZIONE ISTANTANEA (Solo per il Live/Demo)
  // Lo Strategy Tester di MT5 ha un bug con la modalità Asincrona e spesso non
  // apre il secondo trade. Quindi la attiviamo SOLO se NON siamo nel Tester
  // (nel tester il ritardo è 0 di default).
  if (!MQLInfoInteger(MQL_TESTER)) {
    trade.SetAsyncMode(true);
  }

  if (!SymbolSelect(InpSymbol2, true)) {
    Print("Errore: Impossibile selezionare il simbolo ", InpSymbol2);
    return (INIT_FAILED);
  }

  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| Calcola la Correlazione di Pearson tra due array                 |
//+------------------------------------------------------------------+
double CalculateCorrelation(const double &arr1[], const double &arr2[],
                            int count) {
  if (count <= 1)
    return 0.0;

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

  if (den1 * den2 == 0.0)
    return 0.0;
  return num / MathSqrt(den1 * den2);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
  // 1. Calcolo Z-Score dinamico (Spread % normalizzato)
  int calc_period = InpZScorePeriod;
  int total_bars_needed =
      calc_period * 2; // Servono (N + N) candele per calcolare N medie mobili

  double close1[], close2[];
  ArraySetAsSeries(close1, true);
  ArraySetAsSeries(close2, true);

  if (CopyClose(_Symbol, PERIOD_CURRENT, 0, total_bars_needed, close1) <
      total_bars_needed)
    return;
  if (CopyClose(InpSymbol2, PERIOD_CURRENT, 0, total_bars_needed, close2) <
      total_bars_needed)
    return;

  double spread_array[];
  ArrayResize(spread_array, calc_period);
  double sum_spread = 0.0;

  // Calcola lo spread % per le ultime InpZScorePeriod candele
  for (int i = 0; i < calc_period; i++) {
    // Calcola la Media Mobile a 50 periodi per la candela 'i'
    double sum1 = 0.0, sum2 = 0.0;
    for (int j = 0; j < calc_period; j++) {
      sum1 += close1[i + j];
      sum2 += close2[i + j];
    }
    double ma1 = sum1 / calc_period;
    double ma2 = sum2 / calc_period;

    // Calcola la deviazione % del prezzo rispetto alla propria media
    double dev1 = 0.0, dev2 = 0.0;
    if (ma1 > 0.000001)
      dev1 = (close1[i] - ma1) / ma1 * 100.0;
    if (ma2 > 0.000001)
      dev2 = (close2[i] - ma2) / ma2 * 100.0;

    // Il nuovo spread è la differenza tra le deviazioni percentuali
    spread_array[i] = dev1 - dev2;
    sum_spread += spread_array[i];
  }

  // Calcolo spread medio a 50 periodi
  double mean_spread = sum_spread / calc_period;

  double sum_sq_diff = 0.0;
  for (int i = 0; i < calc_period; i++) {
    sum_sq_diff += MathPow(spread_array[i] - mean_spread, 2.0);
  }

  // Calcolo deviazione standard a 50 periodi
  double std_dev = MathSqrt(sum_sq_diff / calc_period);

  double current_price1 = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double current_price2 = SymbolInfoDouble(InpSymbol2, SYMBOL_BID);

  double current_spread = spread_array[0]; // Spread % del tick attuale
  double current_zscore = 0.0;
  if (std_dev > 0.000001)
    current_zscore = (current_spread - mean_spread) / std_dev;

  if (first_tick) {
    last_zscore = current_zscore;
    first_tick = false;
    return;
  }

  // 1.1 Controllo Cooldown
  if (TimeCurrent() < cooldown_until)
    return;

  // 1.5 Calcolo Slope e Banda Dinamica (usate sia in uscita che in ingresso)
  double current_slope = 0.0;
  double peak_z = 2.0; // fallback se non ci sono dati storici
  {
    // Slope: derivata della media mobile dello spread % su InpSlopeWindow barre
    if (calc_period >= InpSlopeWindow + 3) {
      double ma_now = 0.0, ma_prev = 0.0;
      // calcolo spread ora e 3 ore fa media  10 periodi
      for (int k = 0; k < InpSlopeWindow; k++)
        ma_now += spread_array[k];
      for (int k = 3; k < InpSlopeWindow + 3; k++)
        ma_prev += spread_array[k];
      ma_now /= InpSlopeWindow;
      ma_prev /= InpSlopeWindow;
      current_slope = ma_now - ma_prev; // >0 spread % sale, <0 spread % scende
    }

    // Peak Z: massimo Z-Score assoluto negli ultimi InpLookbackBars periodi
    // (Spread % normalizzato)
    int peak_bars_needed = InpLookbackBars + calc_period;
    double hist1[], hist2[];
    ArraySetAsSeries(hist1, true);
    ArraySetAsSeries(hist2, true);
    if (CopyClose(_Symbol, PERIOD_CURRENT, 0, peak_bars_needed, hist1) >=
            peak_bars_needed &&
        CopyClose(InpSymbol2, PERIOD_CURRENT, 0, peak_bars_needed, hist2) >=
            peak_bars_needed) {
      double sum_s = 0.0;
      double spreads[];
      ArrayResize(spreads, InpLookbackBars);

      for (int i = 0; i < InpLookbackBars; i++) {
        // Calcola Media Mobile a 50 periodi per la candela 'i' storica
        double sum1 = 0.0, sum2 = 0.0;
        for (int j = 0; j < calc_period; j++) {
          sum1 += hist1[i + j];
          sum2 += hist2[i + j];
        }
        double ma1 = sum1 / calc_period;
        double ma2 = sum2 / calc_period;

        double dev1 = 0.0, dev2 = 0.0;
        if (ma1 > 0.000001)
          dev1 = (hist1[i] - ma1) / ma1 * 100.0;
        if (ma2 > 0.000001)
          dev2 = (hist2[i] - ma2) / ma2 * 100.0;

        spreads[i] = dev1 - dev2;
        sum_s += spreads[i];
      }
      // calcolo media spread 720 periodi
      double mean_720 = sum_s / InpLookbackBars;
      double sum_sq_720 = 0.0;
      for (int i = 0; i < InpLookbackBars; i++)
        sum_sq_720 += MathPow(spreads[i] - mean_720, 2.0);
      double std_720 = MathSqrt(sum_sq_720 / InpLookbackBars);
      // calcolo deviazione standard 720 periodi
      double max_z = 0.0;
      // calcolo Z-Score massimo assoluto negli ultimi 720 periodi
      for (int i = 0; i < InpLookbackBars; i++) {
        if (std_dev > 0.000001) {
          double zz = MathAbs(spreads[i] - mean_spread) / std_dev;
          // Filtra outlier oltre 3 std storiche
          if (std_720 > 0.000001 &&
              MathAbs(spreads[i] - mean_720) / std_720 > 3.0)
            continue;
          if (zz > max_z)
            max_z = zz;
        }
      }
      if (max_z > 0.0)
        peak_z = max_z;
    }
  }

  // 2. Controlla le posizioni aperte associate a questo EA
  int open_positions = PositionsTotal();
  bool has_our_positions = false;
  int our_positions_count = 0;
  int trade_direction = 0; // 1 per UP (Buy Sym1, Sell Sym2), -1 per DOWN

  for (int i = 0; i < open_positions; i++) {
    ulong ticket = PositionGetTicket(i);
    if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
      has_our_positions = true;
      our_positions_count++;
      // Determina la direzione dalla posizione sull'asset principale
      if (PositionGetString(POSITION_SYMBOL) == _Symbol) {
        if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
          trade_direction = 1;
        else if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
          trade_direction = -1;
      }
    }
  }

  // ORPHAN LEG PROTECTION (Posizione Scoperta)
  // Se c'è una sola posizione (o numero dispari), l'altra ha fallito
  // l'apertura. Dobbiamo chiudere tutto per evitare rischio direzionale netto.
  if (our_positions_count == 1 ||
      (our_positions_count > 0 && our_positions_count % 2 != 0)) {
    Print("ATTENZIONE: Rilevata posizione orfana/scoperta! Chiusura immediata "
          "e COOLDOWN.");
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
        trade.PositionClose(ticket);
      }
    }
    cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    last_zscore = current_zscore; // FIX: Aggiorna lo zscore prima di uscire per
                                  // evitare loop infinito
    return; // Interrompiamo questo tick finché non ha chiuso tutto
  }

  // 3. Logica di Uscita (Uscita target Z-Score + Profitto Globale)
  if (has_our_positions) {
    // Calcola il profitto netto globale (Profitto + Swap + Commissioni) delle
    // posizioni aperte
    double total_net_profit = 0.0;
    for (int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
        total_net_profit += PositionGetDouble(POSITION_PROFIT) +
                            PositionGetDouble(POSITION_SWAP);
      }
    }

    bool close_all = false;

    // CONTROLLO EMERGENZA CIGNO NERO (Rottura strutturale a mercato aperto)
    // guardo semplicemente se
    double current_short_corr = 0.0;
    double temp_h1[], temp_h2[];
    ArraySetAsSeries(temp_h1, true);
    ArraySetAsSeries(temp_h2, true);
    if (CopyClose(_Symbol, PERIOD_CURRENT, 0, InpShortCorrBars, temp_h1) >=
            InpShortCorrBars &&
        CopyClose(InpSymbol2, PERIOD_CURRENT, 0, InpShortCorrBars, temp_h2) >=
            InpShortCorrBars) {
      current_short_corr =
          CalculateCorrelation(temp_h1, temp_h2, InpShortCorrBars);
    }

    // === HARD STOP LOSS MONETARIO (priorità massima) ===
    if (InpMaxLossMoney > 0.0 && total_net_profit <= -InpMaxLossMoney) {
      close_all = true;
      corr_low_since = 0; // reset contatore
      Print("HARD STOP LOSS: Perdita globale (", total_net_profit,
            ") ha superato -", InpMaxLossMoney, " Euro. Chiusura immediata!");
      cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    }
    // === CIGNO NERO PERSISTENTE ===
    // Non uscire alla prima ora di bassa correlazione: avvia un contatore.
    // Se la correlazione si riprende → reset. Solo se persiste N ore → chiudi.
    else if (current_short_corr > 0.0 && current_short_corr < InpMinShortCorr) {
      if (corr_low_since == 0)
        corr_low_since = TimeCurrent(); // prima volta che scende sotto soglia

      int hours_low = (int)((TimeCurrent() - corr_low_since) / 3600);

      if (InpCorrPersistHours == 0 || hours_low >= InpCorrPersistHours) {
        close_all = true;
        corr_low_since = 0;
        Print("CIGNO NERO CONFERMATO: corr24=",
              NormalizeDouble(current_short_corr, 3), " sotto soglia da ",
              hours_low, "h (>=", InpCorrPersistHours, "h). Taglio perdite.");
        cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
      } else
        Print("Correlazione bassa (corr24=",
              NormalizeDouble(current_short_corr, 3), ") da ", hours_low,
              "h - attendo conferma ", InpCorrPersistHours,
              "h prima di uscire.");
    } else {
      // Correlazione tornata normale: reset contatore
      if (corr_low_since != 0) {
        Print("Correlazione ripristinata (corr24=",
              NormalizeDouble(current_short_corr, 3),
              "). Contatore Cigno Nero azzerato. Tengo aperto.");
        corr_low_since = 0;
      }
    }

    // Z-SCORE STOP LOSS STRUTTURALE (controllo indipendente)
    if (!close_all && MathAbs(current_zscore) > InpStopLossDev) {
      close_all = true;
      corr_low_since = 0;
      Print("STOP LOSS STRUTTURALE: Z-Score (", current_zscore,
            ") ha superato il limite di ", InpStopLossDev,
            ". Divergenza fuori controllo!");
      cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
    }
    // === USCITA 1: TARGET — Z torna alla media (Z=0, mean reversion completa)
    // ===
    if (!close_all) {
      if (trade_direction == -1 && current_zscore <= 0.0) {
        close_all = true;
        Print("[TARGET] Z tornato a media (Z=",
              NormalizeDouble(current_zscore, 3),
              "). SELL spread completato. P/L=", total_net_profit);
      } else if (trade_direction == 1 && current_zscore >= 0.0) {
        close_all = true;
        Print("[TARGET] Z tornato a media (Z=",
              NormalizeDouble(current_zscore, 3),
              "). BUY spread completato. P/L=", total_net_profit);
      }
    }

    // === USCITA 2: SLOPE INVERTITA — la mean reversion ha perso slancio ===
    if (!close_all && slope_sign_at_entry != 0.0 && position_open_time > 0) {
      double current_slope_sign =
          (current_slope > 0.0)
              ? 1.0
              : ((current_slope < 0.0) ? -1.0 : slope_sign_at_entry);
      int hours_open = (int)((TimeCurrent() - position_open_time) / 3600);
      bool slope_reversed = (current_slope_sign != slope_sign_at_entry);

      if (slope_reversed && hours_open >= InpSlopeMinHours) {
        if (total_net_profit > 0.0) {
          close_all = true;
          Print("[SLOPE_REV] Slope invertita dopo ", hours_open,
                "h. Chiusura in PROFITTO: +", total_net_profit);
        }
        // non mi piace
        else if (total_net_profit > -10.0) {
          close_all = true;
          Print("[SLOPE_REV] Slope invertita dopo ", hours_open,
                "h. Perdita contenuta: ", total_net_profit,
                ". Chiusura preventiva.");
        } else
          Print("[SLOPE_WATCH] Slope invertita dopo ", hours_open,
                "h ma perdita troppo alta (", total_net_profit,
                "). Attendo recupero.");
      }
    }

    if (close_all) {
      slope_sign_at_entry = 0.0;
      position_open_time = 0;
      for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
          trade.PositionClose(ticket);
        }
      }
    }
  }
  // 4. Logica di Ingresso con FILTRO SLOPE (solo se non abbiamo posizioni
  // aperte)
  if (!has_our_positions) {
    // Banda dinamica: % del picco Z storico
    double entry_band = peak_z * InpPeakZMultiplier;
    if (entry_band < InpBandMin)
      entry_band = InpBandMin;

    // CONDIZIONE DI ATTIVAZIONE:
    // Z-Score è OLTRE la banda (non solo nel tick di incrocio)
    // E la slope CONFERMA che il movimento di ritorno è già iniziato
    // Guard: last_zscore deve essere < entry_band (evita re-entrata continua)
    bool in_zone_high = (current_zscore > entry_band);
    bool in_zone_low = (current_zscore < -entry_band);

    // Filtro guard: non rientrare se eravamo già oltre la banda (già dentro la
    // zona)
    bool fresh_entry_high =
        (last_zscore <= entry_band); // eravamo sotto, ora sopra
    bool fresh_entry_low =
        (last_zscore >= -entry_band); // eravamo sopra, ora sotto

    // SLOPE conferma: lo spread si sta già girando verso la media
    bool trigger_short =
        in_zone_high && fresh_entry_high && (current_slope < 0.0);
    bool trigger_long = in_zone_low && fresh_entry_low && (current_slope > 0.0);

    // Modalità ZONA ESTESA: se Z > entry_band*1.3 e slope concorde, entra anche
    // senza fresh
    double extended_band = entry_band * 1.3;
    if (!trigger_short && current_zscore > extended_band && current_slope < 0.0)
      trigger_short = true;
    if (!trigger_long && current_zscore < -extended_band && current_slope > 0.0)
      trigger_long = true;

    if (trigger_short || trigger_long) {
      // FILTRO CORRELAZIONE
      double corr = 0.0;
      double h1[], h2[];
      ArraySetAsSeries(h1, true);
      ArraySetAsSeries(h2, true);
      double short_corr = 0.0;
      if (CopyClose(_Symbol, PERIOD_CURRENT, 0, InpLookbackBars, h1) >=
              InpLookbackBars &&
          CopyClose(InpSymbol2, PERIOD_CURRENT, 0, InpLookbackBars, h2) >=
              InpLookbackBars) {
        corr = CalculateCorrelation(h1, h2, InpLookbackBars);
        short_corr = CalculateCorrelation(h1, h2, InpShortCorrBars);
      }

      if (corr < InpMinCorrelation)
        Print("INGRESSO BLOCCATO: Corr720 troppo bassa (",
              NormalizeDouble(corr, 2), ").");
      else if (short_corr < InpMinShortCorr)
        Print("INGRESSO BLOCCATO: Corr24 instabile (",
              NormalizeDouble(short_corr, 2), ").");
      else {
        // BILANCIAMENTO VOLUMI
        double lot_step2 = SymbolInfoDouble(InpSymbol2, SYMBOL_VOLUME_STEP);
        if (lot_step2 <= 0.0)
          lot_step2 = 0.01;
        double min_lot2 = SymbolInfoDouble(InpSymbol2, SYMBOL_VOLUME_MIN);
        double raw_lot2 = InpLotSize * (current_price1 / current_price2);
        double lot_size2 = MathRound(raw_lot2 / lot_step2) * lot_step2;
        lot_size2 = NormalizeDouble(lot_size2, 2);
        if (lot_size2 < min_lot2)
          lot_size2 = min_lot2;

        // PRE-CHECK MARGINE
        double margin1 = 0, margin2 = 0;
        if (!OrderCalcMargin(trigger_long ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                             _Symbol, InpLotSize, current_price1, margin1))
          margin1 = 1000;
        if (!OrderCalcMargin(trigger_long ? ORDER_TYPE_SELL : ORDER_TYPE_BUY,
                             InpSymbol2, lot_size2, current_price2, margin2))
          margin2 = 1000;

        if (AccountInfoDouble(ACCOUNT_MARGIN_FREE) <
            (margin1 + margin2) * 1.5) {
          Print("INGRESSO BLOCCATO: Margine insufficiente. Richiesto: ",
                margin1 + margin2,
                " Libero: ", AccountInfoDouble(ACCOUNT_MARGIN_FREE));
          cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
        } else {
          if (trigger_short) {
            bool res1 = trade.Sell(InpLotSize, _Symbol);
            if (!res1)
              Print("Errore SELL su ", _Symbol, " -> ", trade.ResultComment());
            else {
              bool res2 = trade.Buy(lot_size2, InpSymbol2);
              if (!res2) {
                Print("Errore BUY su ", InpSymbol2, " -> ",
                      trade.ResultComment(), ". Chiusura leg 1.");
                trade.PositionClose(_Symbol);
                cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
              } else {
                slope_sign_at_entry =
                    -1.0; // SELL spread: slope doveva essere <0
                position_open_time = TimeCurrent();
                Print("[SLOPE+BAND] SELL ", _Symbol, " / BUY ", InpSymbol2,
                      " | Z=", NormalizeDouble(current_zscore, 3),
                      " | Band=", NormalizeDouble(entry_band, 3),
                      " | Slope=", NormalizeDouble(current_slope, 6));
              }
            }
          } else if (trigger_long) {
            bool res1 = trade.Buy(InpLotSize, _Symbol);
            if (!res1)
              Print("Errore BUY su ", _Symbol, " -> ", trade.ResultComment());
            else {
              bool res2 = trade.Sell(lot_size2, InpSymbol2);
              if (!res2) {
                Print("Errore SELL su ", InpSymbol2, " -> ",
                      trade.ResultComment(), ". Chiusura leg 1.");
                trade.PositionClose(_Symbol);
                cooldown_until = TimeCurrent() + InpCooldownHours * 3600;
              } else {
                slope_sign_at_entry = 1.0; // BUY spread: slope doveva essere >0
                position_open_time = TimeCurrent();
                Print("[SLOPE+BAND] BUY ", _Symbol, " / SELL ", InpSymbol2,
                      " | Z=", NormalizeDouble(current_zscore, 3),
                      " | Band=", NormalizeDouble(entry_band, 3),
                      " | Slope=", NormalizeDouble(current_slope, 6));
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
