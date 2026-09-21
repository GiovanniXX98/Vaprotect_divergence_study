# Vaprotect Divergence: Statistical Arbitrage & Mean Reversion 

## 📌 Project Overview
This repository contains a quantitative trading study and the associated MQL5 Expert Advisor (EA) for **Statistical Arbitrage (Pairs Trading)**. The project focuses on exploiting temporary market inefficiencies between highly correlated assets (e.g., EURUSD and GBPUSD) using statistical mean reversion.

The system is built to identify structural anomalies in the price spread and capitalize on the mathematical probability of the assets returning to their historical mean, maintaining a delta-neutral (market-neutral) exposure.

## ⚙️ Core Architecture & Mathematics

Instead of relying on nominal price differences which are subject to drift, the EA calculates the **Normalized Percentage Spread**. The core engine evaluates:

1. **Percentage Deviation**: Evaluates the distance of each asset from its 50-period moving average in percentage terms.
2. **Z-Score Calculation**: Normalizes the spread using its standard deviation (`Z = (Spread - Mean) / StdDev`), creating a dynamic threshold that adapts to current market volatility.
3. **Slope (Derivative) Filter**: Prevents entering trades against aggressive momentum. The EA waits for the derivative of the spread to flatten/reverse (Slope confirmation) before pulling the trigger.
4. **Dynamic Correlation Filters**: 
   - **Macro Filter (720-period)**: Ensures structural correlation exists before trading.
   - **Black Swan Filter (24-period)**: Acts as a safety net. If short-term correlation completely collapses for an extended period, the system identifies a structural break (Black Swan) and cuts exposure to prevent account ruin.

## 📂 Repository Contents

- `Vaprotect_Divergence.mq5`: The main Expert Advisor code written in MQL5 for the MetaTrader 5 platform. Contains institutional-grade logic for asynchronous execution, margin protection, and risk management.
- **Python Data Studies (`/globale`, `/720_periodi`, etc.)**: A suite of high-resolution data visualizations generated via Python (pandas/matplotlib). These graphs analyze 2 years of historical hourly data across various time horizons (10, 50, 720 periods), plotting:
  - Price Action vs Percentage Spread
  - Spread Standard Deviation (Volatility)
  - Asset Correlation Breakdown
## 🛡️ Institutional Risk Management

A robust algorithmic system is defined by its ability to protect capital during edge cases. This EA includes:
- **Orphan Leg Protection**: Arbitrage requires two simultaneous trades. If the broker rejects one leg (e.g., due to slippage, margin limits, or requotes), the EA immediately detects the isolated trade and closes it to prevent naked directional exposure.
- **Structural Stop Loss**: A hard-coded Z-Score stop loss (e.g., Z > 4.5) to cut losses if the mathematical relationship between the pairs permanently breaks.
- **Cooldown Mechanism**: After a Stop Loss or a Black Swan event, the EA enters a mandatory cooldown period (e.g., 4 hours) to prevent "revenge trading" or getting chopped in a highly volatile market.

## 🧪 Custom Backtesting Framework

Before writing MQL5, the logic was rigorously tested using a custom event-driven backtesting engine written in Python. The repository reflects this dual approach:
- **Python (Research Phase)**: Fast iteration, data visualization, and proof-of-concept testing using `pandas` and `yfinance`.
- **MQL5 (Deployment Phase)**: Low-latency execution, asynchronous order routing, and live market deployment.

## 🛠️ Tech Stack & Dependencies

- **Trading Engine**: MQL5 (MetaQuotes Language 5)
- **Data Analysis & Modeling**: Python 3.12
- **Libraries**: `pandas`, `numpy`, `matplotlib`, `yfinance`

## 🚀 Future Developments

The next phase of this quantitative project focuses on parameter optimization through machine learning techniques:
- **Genetic Algorithm Optimization**: Utilizing the MetaTrader 5 Strategy Tester to run genetic algorithms across historical tick data. This will identify the mathematically optimal lookback periods for the moving averages, Z-Score thresholds, and slope windows based on the Pareto principle (targeting the top 20% of extreme market anomalies).

---
*Developed as a showcase of algorithmic trading, statistical market analysis, and C++ (MQL5) / Python integration.*
