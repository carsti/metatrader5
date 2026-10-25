//+------------------------------------------------------------------+
//|                                        AURUM TREND SYSTEM.mq5   |
//|                                          Copyright 2024, Carsten |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2024, Carsten"
#property link        ""
#property version     "1.00"
#property description "Trend-Following EA for XAUUSD M5"
#property description "MTF EMA50 + ATR SL/TP + ADX filter — No Grid, No Martingale"

#include <EAUtils.mqh>


input group "Strategy"
input double InpRiskPercent     = 1.0;   // Risk Per Trade (% of Balance)
input double InpATRMultSL       = 1.5;   // ATR Multiplier for SL
input double InpRRRatio         = 2.0;   // Risk:Reward Ratio (TP = SL * ratio)
input bool   InpUseTrailingStop = false; // Use Trailing Stop
input double InpTrailingLevel   = 50.0;  // Trailing Stop Level (% of SL distance)

input group "Filters"
input bool   InpUseSessionFilter = true; // Session Filter Enable
input int    InpSessionStart     = 8;    // Session Start Hour (UTC)
input int    InpSessionEnd       = 17;   // Session End Hour (UTC)
input int    InpADXPeriod        = 14;   // ADX Period
input double InpADXMinLevel      = 20.0; // Minimum ADX Level (Trend Strength)

input group "Risk Controls"
input double InpMaxDailyLoss = 50.0; // Max Daily Loss (USD, 0=Disable)
input double InpMaxDD        = 20.0; // Max Drawdown (%, 0=Disable)

input group "News"
input bool                 News           = false;                   // News Filter Enable
input ENUM_NEWS_IMPORTANCE NewsImportance = NEWS_IMPORTANCE_MEDIUM;  // News Importance
input int                  NewsMinsBefore = 60;                      // News Minutes Before
input int                  NewsMinsAfter  = 60;                      // News Minutes After
input int                  NewsStartYear  = 0;                       // News Start Year for Backtesting (0=Disable)

input group "Auxiliary"
input int          Slippage      = 30;             // Slippage (Points)
input int          TimerInterval = 30;             // Timer Interval (Seconds)
input ulong        MagicNumber   = 20241025;       // Magic Number
input ENUM_FILLING Filling       = FILLING_DEFAULT; // Order Filling


GerEA    ea;
datetime lastCandle;
datetime tc;

// Indicator handles
int h_EMA_M5, h_EMA_M15, h_EMA_H1;
int h_RSI_M5;
int h_ATR_M5;
int h_ADX_H1;

// Indicator buffers
double EMA_M5[], EMA_M15[], EMA_H1[];
double RSI_M5[];
double ATR_M5[];
double ADX_H1[], DI_Plus_H1[], DI_Minus_H1[];

// Safety state
bool     eaStopped;
double   peakBalance;

// Dashboard
#define DASH_PREFIX "ATS_"


//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void DashLabel(string name, int x, int y, string text,
               color clr = clrSilver, int fontSize = 9) {
    string obj = DASH_PREFIX + name;
    if (ObjectFind(0, obj) < 0)
        ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, obj, OBJPROP_XDISTANCE,  x);
    ObjectSetInteger(0, obj, OBJPROP_YDISTANCE,  y);
    ObjectSetInteger(0, obj, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
    ObjectSetInteger(0, obj, OBJPROP_COLOR,      clr);
    ObjectSetInteger(0, obj, OBJPROP_FONTSIZE,   fontSize);
    ObjectSetString (0, obj, OBJPROP_FONT,       "Courier New");
    ObjectSetString (0, obj, OBJPROP_TEXT,       text);
    ObjectSetInteger(0, obj, OBJPROP_SELECTABLE, false);
}

void DashUpdate() {
    const int X = 10;
    int y = 20;
    const int LH = 16;

    DashLabel("title", X, y, "AURUM TREND SYSTEM", clrGold, 10);
    y += LH + 2;

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double openPnl = equity - balance;

    DashLabel("bal", X, y, StringFormat("Balance : %10.2f", balance));
    y += LH;
    DashLabel("eq",  X, y,
              StringFormat("Equity  : %10.2f  (%+.2f)", equity, openPnl),
              openPnl >= 0 ? clrLimeGreen : clrTomato);
    y += LH;

    double adxVal = (ArraySize(ADX_H1) > 1) ? ADX_H1[1] : 0;
    DashLabel("adx", X, y,
              StringFormat("ADX(H1) : %6.1f  [%s]", adxVal,
                           adxVal >= InpADXMinLevel ? "TRENDING" : "RANGING "),
              adxVal >= InpADXMinLevel ? clrLimeGreen : clrOrangeRed);
    y += LH;

    string trendStr = "NEUTRAL";
    color  trendClr = clrSilver;
    if (ArraySize(EMA_M5) > 1 && ArraySize(EMA_M15) > 1 && ArraySize(EMA_H1) > 1) {
        double c  = Close(1);
        double e5 = EMA_M5[1], e15 = EMA_M15[1], e1h = EMA_H1[1];
        if (c > e5 && c > e15 && c > e1h)  { trendStr = "BULLISH"; trendClr = clrLimeGreen; }
        else if (c < e5 && c < e15 && c < e1h) { trendStr = "BEARISH"; trendClr = clrTomato;    }
    }
    DashLabel("trend", X, y, StringFormat("Trend   : %s", trendStr), trendClr);
    y += LH;

    double rsiVal = (ArraySize(RSI_M5) > 1) ? RSI_M5[1] : 0;
    color rsiClr = (rsiVal >= 40 && rsiVal <= 60) ? clrLimeGreen : clrOrangeRed;
    DashLabel("rsi", X, y, StringFormat("RSI(M5) : %6.1f  [%s]", rsiVal,
              (rsiVal >= 40 && rsiVal <= 60) ? "OK " : "OB/OS"), rsiClr);
    y += LH;

    int  ops    = ea.OPTotal();
    double posP = 0;
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            posP += PositionGetDouble(POSITION_PROFIT);
    }
    if (ops > 0)
        DashLabel("pos", X, y,
                  StringFormat("Position: %d open  P/L: %+.2f", ops, posP),
                  posP >= 0 ? clrLimeGreen : clrTomato);
    else
        DashLabel("pos", X, y, "Position: none");
    y += LH;

    DashLabel("status", X, y,
              StringFormat("Status  : %s", eaStopped ? "STOPPED" : "ACTIVE "),
              eaStopped ? clrTomato : clrLimeGreen);

    ChartRedraw(0);
}

void DashDelete() {
    ObjectsDeleteAll(0, DASH_PREFIX);
}


//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool IsInSession() {
    if (!InpUseSessionFilter) return true;
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    return (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
}

double GetDailyProfit() {
    MqlDateTime startDt;
    TimeToStruct(TimeCurrent(), startDt);
    startDt.hour = 0; startDt.min = 0; startDt.sec = 0;
    datetime dayStart = StructToTime(startDt);

    double profit = 0;
    if (HistorySelect(dayStart, TimeCurrent())) {
        for (int i = 0; i < HistoryDealsTotal(); i++) {
            ulong tk = HistoryDealGetTicket(i);
            if ((ulong)HistoryDealGetInteger(tk, DEAL_MAGIC) != MagicNumber) continue;
            if (HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT)     continue;
            profit += HistoryDealGetDouble(tk, DEAL_PROFIT)
                    + HistoryDealGetDouble(tk, DEAL_COMMISSION)
                    + HistoryDealGetDouble(tk, DEAL_SWAP);
        }
    }
    // Include floating P/L of open positions
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            profit += PositionGetDouble(POSITION_PROFIT);
    }
    return profit;
}

bool IsDailyLossBreached() {
    if (InpMaxDailyLoss <= 0) return false;
    return (GetDailyProfit() <= -InpMaxDailyLoss);
}

bool IsMaxDDBreached() {
    if (InpMaxDD <= 0) return false;
    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    if (peakBalance <= 0) return false;
    double ddPct = (peakBalance - equity) / peakBalance * 100.0;
    return (ddPct >= InpMaxDD);
}


//+------------------------------------------------------------------+
//| Signals                                                          |
//+------------------------------------------------------------------+
bool BuySignal() {
    if (ArraySize(EMA_M5)  < 2) return false;
    if (ArraySize(EMA_M15) < 2) return false;
    if (ArraySize(EMA_H1)  < 2) return false;
    if (ArraySize(RSI_M5)  < 2) return false;
    if (ArraySize(ATR_M5)  < 2) return false;
    if (ArraySize(ADX_H1)  < 2) return false;

    double c = Close(1);

    // MTF EMA50: price above EMA on all 3 timeframes
    if (!(c > EMA_M5[1] && c > EMA_M15[1] && c > EMA_H1[1])) return false;

    // RSI 40–60: no overbought entry
    if (RSI_M5[1] < 40.0 || RSI_M5[1] > 60.0) return false;

    // ADX: trending market
    if (ADX_H1[1] < InpADXMinLevel) return false;

    double in   = Ask();
    double atr  = ATR_M5[1];
    double sl   = in - InpATRMultSL * atr;
    double dist = MathAbs(in - sl);
    double tp   = in + InpRRRatio * dist;

    ea.BuyOpen(in, sl, tp, false, false);
    return true;
}

bool SellSignal() {
    if (ArraySize(EMA_M5)  < 2) return false;
    if (ArraySize(EMA_M15) < 2) return false;
    if (ArraySize(EMA_H1)  < 2) return false;
    if (ArraySize(RSI_M5)  < 2) return false;
    if (ArraySize(ATR_M5)  < 2) return false;
    if (ArraySize(ADX_H1)  < 2) return false;

    double c = Close(1);

    // MTF EMA50: price below EMA on all 3 timeframes
    if (!(c < EMA_M5[1] && c < EMA_M15[1] && c < EMA_H1[1])) return false;

    // RSI 40–60: no oversold entry
    if (RSI_M5[1] < 40.0 || RSI_M5[1] > 60.0) return false;

    // ADX: trending market
    if (ADX_H1[1] < InpADXMinLevel) return false;

    double in   = Bid();
    double atr  = ATR_M5[1];
    double sl   = in + InpATRMultSL * atr;
    double dist = MathAbs(sl - in);
    double tp   = in - InpRRRatio * dist;

    ea.SellOpen(in, sl, tp, false, false);
    return true;
}


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    ea.Init();
    ea.SetMagic(MagicNumber);
    ea.risk             = InpRiskPercent * 0.01;
    ea.riskMode         = RISK_BALANCE;
    ea.slippage         = Slippage;
    ea.filling          = Filling;
    ea.news             = News;
    ea.newsImportance   = NewsImportance;
    ea.newsMinsBefore   = NewsMinsBefore;
    ea.newsMinsAfter    = NewsMinsAfter;
    ea.martingale       = false;
    ea.grid             = false;
    ea.trailingStopLevel = InpUseTrailingStop ? InpTrailingLevel * 0.01 : 0;
    ea.equityDrawdownLimit = 0; // handled by InpMaxDD

    if (News) fetchCalendarFromYear(NewsStartYear);

    h_EMA_M5  = iMA  (NULL, PERIOD_M5,  50, 0, MODE_EMA, PRICE_CLOSE);
    h_EMA_M15 = iMA  (NULL, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
    h_EMA_H1  = iMA  (NULL, PERIOD_H1,  50, 0, MODE_EMA, PRICE_CLOSE);
    h_RSI_M5  = iRSI (NULL, PERIOD_M5,  14, PRICE_CLOSE);
    h_ATR_M5  = iATR (NULL, PERIOD_M5,  14);
    h_ADX_H1  = iADX (NULL, PERIOD_H1,  InpADXPeriod);

    if (h_EMA_M5  == INVALID_HANDLE || h_EMA_M15 == INVALID_HANDLE ||
        h_EMA_H1  == INVALID_HANDLE || h_RSI_M5  == INVALID_HANDLE ||
        h_ATR_M5  == INVALID_HANDLE || h_ADX_H1  == INVALID_HANDLE) {
        Print("AURUM: Failed to create indicator handles: ", GetLastError());
        return INIT_FAILED;
    }

    peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    eaStopped   = false;

    EventSetTimer(TimerInterval);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
    DashDelete();
    IndicatorRelease(h_EMA_M5);
    IndicatorRelease(h_EMA_M15);
    IndicatorRelease(h_EMA_H1);
    IndicatorRelease(h_RSI_M5);
    IndicatorRelease(h_ATR_M5);
    IndicatorRelease(h_ADX_H1);
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
    datetime oldTc = tc;
    tc = TimeCurrent();
    if (tc == oldTc) return;

    if (InpUseTrailingStop && ea.trailingStopLevel > 0)
        ea.CheckForTrail();

    // Update peak balance for DD tracking
    double bal = AccountInfoDouble(ACCOUNT_BALANCE);
    if (bal > peakBalance) peakBalance = bal;

    DashUpdate();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    if (lastCandle != Time(0)) {
        lastCandle = Time(0);

        // --- Copy indicators ---
        if (CopyBuffer(h_EMA_M5,  0, 0, 3, EMA_M5)       <= 0) return;
        if (CopyBuffer(h_EMA_M15, 0, 0, 3, EMA_M15)      <= 0) return;
        if (CopyBuffer(h_EMA_H1,  0, 0, 3, EMA_H1)       <= 0) return;
        if (CopyBuffer(h_RSI_M5,  0, 0, 3, RSI_M5)       <= 0) return;
        if (CopyBuffer(h_ATR_M5,  0, 0, 3, ATR_M5)       <= 0) return;
        if (CopyBuffer(h_ADX_H1,  0, 0, 3, ADX_H1)       <= 0) return;
        if (CopyBuffer(h_ADX_H1,  1, 0, 3, DI_Plus_H1)   <= 0) return;
        if (CopyBuffer(h_ADX_H1,  2, 0, 3, DI_Minus_H1)  <= 0) return;

        ArraySetAsSeries(EMA_M5,      true);
        ArraySetAsSeries(EMA_M15,     true);
        ArraySetAsSeries(EMA_H1,      true);
        ArraySetAsSeries(RSI_M5,      true);
        ArraySetAsSeries(ATR_M5,      true);
        ArraySetAsSeries(ADX_H1,      true);
        ArraySetAsSeries(DI_Plus_H1,  true);
        ArraySetAsSeries(DI_Minus_H1, true);

        // --- Safety guards ---
        double bal = AccountInfoDouble(ACCOUNT_BALANCE);
        if (bal > peakBalance) peakBalance = bal;

        if (!eaStopped && IsMaxDDBreached()) {
            eaStopped = true;
            Print("AURUM TREND SYSTEM: Max Drawdown limit reached — EA stopped.");
        }
        if (eaStopped) return;

        if (IsDailyLossBreached()) return;

        // --- Gate checks ---
        if (ea.OPTotal() > 0)  return; // max 1 position
        if (!IsInSession())    return; // session filter

        // --- Entry ---
        if (BuySignal())  return;
        SellSignal();
    }
}
//+------------------------------------------------------------------+
