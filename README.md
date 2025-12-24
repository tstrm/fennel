# fennel
Automate trading with Fennel brokerage API

Fennel is a smartphone app-only brokerage. The app is notoriously slow and buggy, and this is my workaround.
These are some simple scripts written in Perl to interact with the Fennel brokerage's API.

Go to https://dash.fennel.com/ to create your Personal Access Token (PAT).

The first time you run any of these scripts, it will ask for the PAT and create a fennel.conf file, and then read the PAT from that file the next time you run a script.

### fennel-portfolio.pl
Displays holdings in all accounts.

### fennel-buy.pl
Asks for a stock symbol and account, and buys 1 share at market.

### fennel-sell_$2+.pl
Checks holdings for all accounts and attempts to close any position valued $2 or more.

## Windows
Download the .exe files to run on Windows without having to install a Perl interpreter.


Credit to claude.ai for helping generate some of the code.
