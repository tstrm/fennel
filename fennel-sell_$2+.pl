#!perl

use strict;
use warnings;
use open ':std', ':encoding(UTF-8)';

use Win32::Console; 
my $objConsole = Win32::Console->new;
$objConsole->Title('Fennel Sell > $2');

use LWP::UserAgent;
use JSON;

# Configuration
my $API_BASE = "https://api.fennel.com";
my $PAT_TOKEN = '';
# $ENV{'DEBUG'} = 1;
my $THRESHOLD = 2.00;  # Sell stocks with value >= $2.00
my $DELAY_SECONDS = 15;  # Delay between orders (increase if hitting rate limits)

if (-e 'fennel.conf')
{
	open my $fhConf, '<', 'fennel.conf';
	
	my $strConf = '';
	
	while (<$fhConf>)
	{
		$strConf .= $_;
	}
	
	close $fhConf;
	
	if ($strConf =~ /PAT_TOKEN=(.*?)$/)
	{
		$PAT_TOKEN = $1;
	}
}

if ($PAT_TOKEN eq '')
{
	print "Please visit https://dash.fennel.com/ and generate a new Personal Access Token. Enter it below to continue.\n";
	print "Personal Access Token (PAT): ";
	
	my $strInput = <STDIN>;
	
	chomp($strInput);
	
	$PAT_TOKEN = $strInput;
	
	open my $fhConf, '>', 'fennel.conf';
	
	print $fhConf "PAT_TOKEN=$strInput\n";

	close $fhConf;
}


# Initialize HTTP client
my $ua = LWP::UserAgent->new(
    timeout => 30,
    agent => 'Fennel-Perl-Client/1.0',
);

# Set up headers with authentication
my %headers = (
    'Authorization' => "Bearer $PAT_TOKEN",
    'Content-Type' => 'application/json',
    'Accept' => 'application/json',
);

sub api_request {
    my ($method, $endpoint, $data) = @_;
    
    my $url = "$API_BASE$endpoint";
    print "DEBUG: Making $method request to: $url\n" if $ENV{'DEBUG'};
    
    my $request;
    
    if ($method eq 'GET') {
        $request = HTTP::Request->new(GET => $url);
    } elsif ($method eq 'POST') {
        $request = HTTP::Request->new(POST => $url);
        if ($data) {
            my $json_data = encode_json($data);
            print "DEBUG: Request body: $json_data\n" if $ENV{'DEBUG'};
            $request->content($json_data);
        }
    }
    
    # Add headers
    foreach my $key (keys %headers) {
        $request->header($key => $headers{$key});
    }
    
    my $response = $ua->request($request);
    
    print "DEBUG: Response status: " . $response->status_line . "\n" if $ENV{'DEBUG'};
    print "DEBUG: Response body: " . $response->content . "\n" if $ENV{'DEBUG'};
    
    if ($response->is_success) {
        return decode_json($response->content);
    } else {
        die "API Error: " . $response->status_line . "\n" . $response->content . "\n";
    }
}

sub get_account_info {
    my $result = api_request('GET', '/accounts/info');
    return $result;
}

sub get_portfolio_positions {
    my ($account_id) = @_;
    my $positions = api_request('POST', '/portfolio/positions', { account_id => $account_id });
    return $positions;
}

sub create_order {
    my ($account_id, $symbol, $shares, $side) = @_;
    
    # From OpenAPI spec:
    # side: BUY (1), SELL (2)
    # type: MARKET (1)
    # time_in_force: DAY (1)
    # route: EXCHANGE (1)
    
    my $order_data = {
        account_id => $account_id,
        symbol => $symbol,
        shares => abs($shares),  # Ensure positive number
        side => $side eq 'BUY' ? 1 : 2,
        type => 1,  # MARKET
        time_in_force => 1,  # DAY
        route => 1,  # EXCHANGE
    };
    
    my $result = api_request('POST', '/order/create', $order_data);
    return $result;
}

sub format_currency {
    my ($amount) = @_;
    return sprintf("\$%.2f", $amount || 0);
}

sub get_account_type_name {
    my ($type_code) = @_;
    return 'N/A' unless defined $type_code;
    my %types = (
        0 => 'Cash Account',
        1 => 'Traditional IRA',
        2 => 'Roth IRA',
    );
    return $types{$type_code} || "Unknown ($type_code)";
}

# Main execution
print "=" x 70 . "\n";
print "Fennel Auto-Sell Stocks Above Threshold\n";
print "=" x 70 . "\n";
print "Threshold: " . format_currency($THRESHOLD) . " or more\n";
print "=" x 70 . "\n\n";

# Get all accounts
print "Fetching your accounts...\n";
my $accounts_data = get_account_info();
my $accounts = $accounts_data->{accounts};

unless (ref($accounts) eq 'ARRAY' && @$accounts > 0) {
    die "Error: No accounts found\n";
}

print "Found " . scalar(@$accounts) . " account(s)\n\n";

my @all_stocks_to_sell;
my %account_stocks;

# Scan all accounts for stocks above threshold
foreach my $account (@$accounts) {
    my $account_id = $account->{id};
    my $account_name = $account->{name} || 'Unknown Account';
    my $account_type = get_account_type_name($account->{account_type});
    
    print "Scanning account: $account_name ($account_type)\n";
    
    # Get positions
    my $positions_data = get_portfolio_positions($account_id);
    my $positions = $positions_data->{positions};
    
    if (ref($positions) eq 'ARRAY' && @$positions > 0) {
        my @stocks_to_sell;
        
        foreach my $position (@$positions) {
            my $symbol = $position->{symbol};
            my $shares = $position->{shares};
            my $value = $position->{value};
            
            # Only consider long positions (positive shares) with value >= threshold
            if ($shares > 0 && $value >= $THRESHOLD) {
                push @stocks_to_sell, {
                    symbol => $symbol,
                    shares => $shares,
                    value => $value,
                };
                print "  - $symbol: $shares shares @ " . format_currency($value) . " [WILL SELL]\n";
            }
        }
        
        if (@stocks_to_sell) {
            $account_stocks{$account_id} = {
                account => $account,
                stocks => \@stocks_to_sell,
            };
            push @all_stocks_to_sell, @stocks_to_sell;
        } else {
            print "  No stocks above threshold in this account\n";
        }
    } else {
        print "  No positions in this account\n";
    }
    
    print "\n";
}

# Check if there are any stocks to sell
unless (@all_stocks_to_sell) {
    print "=" x 70 . "\n";
    print "No stocks found with value >= " . format_currency($THRESHOLD) . "\n";
    print "=" x 70 . "\n";
    exit 0;
}

# Display summary
print "=" x 70 . "\n";
print "SELL ORDER SUMMARY\n";
print "=" x 70 . "\n";
printf "%-12s %10s %15s %15s\n", "Symbol", "Shares", "Value", "Account";
print "-" x 70 . "\n";

my $total_value = 0;
foreach my $account_id (sort keys %account_stocks) {
    my $account_name = $account_stocks{$account_id}{account}{name};
    foreach my $stock (@{$account_stocks{$account_id}{stocks}}) {
        printf "%-12s %10.4f %15s %15s\n",
            $stock->{symbol},
            $stock->{shares},
            format_currency($stock->{value}),
            $account_name;
        $total_value += $stock->{value};
    }
}

print "-" x 70 . "\n";
printf "%-12s %10s %15s\n", "TOTAL", "", format_currency($total_value);
print "=" x 70 . "\n";

print "\nTotal stocks to sell: " . scalar(@all_stocks_to_sell) . "\n";
print "Total estimated value: " . format_currency($total_value) . "\n\n";

print "WARNING: This will place MARKET SELL orders for all stocks listed above.\n";
print "Market orders execute at the next available price.\n\n";

# Confirm
print "Do you want to proceed? (yes/no): ";
my $confirm = <STDIN>;
chomp($confirm);

unless (lc($confirm) eq 'yes' || lc($confirm) eq 'y') {
    print "\nOperation cancelled.\n";
    exit 0;
}

print "\n";
print "=" x 70 . "\n";
print "PLACING SELL ORDERS\n";
print "=" x 70 . "\n\n";

# Place orders
my $success_count = 0;
my $fail_count = 0;
my @results;
my $order_count = 0;
my $total_orders = scalar(@all_stocks_to_sell);

foreach my $account_id (sort keys %account_stocks) {
    my $account_name = $account_stocks{$account_id}{account}{name};
    
    print "Processing account: $account_name\n";
    print "-" x 70 . "\n";
    
    foreach my $stock (@{$account_stocks{$account_id}{stocks}}) {
        my $symbol = $stock->{symbol};
        my $shares = $stock->{shares};
        my $value = $stock->{value};
        
        $order_count++;
        print "[$order_count/$total_orders] Selling $symbol ($shares shares @ " . format_currency($value) . ")... ";
        
        my $order_result;
        eval {
            $order_result = create_order(
                $account_id,
                $symbol,
                $shares,
                'SELL'
            );
        };
        
        if ($@) {
            print "FAILED\n";
            print "  Error: $@";
            $fail_count++;
            push @results, {
                symbol => $symbol,
                shares => $shares,
                value => $value,
                account => $account_name,
                success => 0,
                error => $@,
            };
        } elsif ($order_result->{success}) {
            print "SUCCESS\n";
            print "  Order ID: $order_result->{id}\n";
            print "  Status: $order_result->{status}\n";
            $success_count++;
            push @results, {
                symbol => $symbol,
                shares => $shares,
                value => $value,
                account => $account_name,
                success => 1,
                order_id => $order_result->{id},
                status => $order_result->{status},
            };
        } else {
            print "FAILED\n";
            print "  Status: $order_result->{status}\n";
            $fail_count++;
            push @results, {
                symbol => $symbol,
                shares => $shares,
                value => $value,
                account => $account_name,
                success => 0,
                status => $order_result->{status},
            };
        }
        
        # Add delay between orders to avoid rate limiting
        if ($order_count < $total_orders) {
            print "  Waiting ${DELAY_SECONDS}s before next order...\n";
            sleep($DELAY_SECONDS);
        }
    }
    
    print "\n";
}

# Final summary
print "=" x 70 . "\n";
print "RESULTS SUMMARY\n";
print "=" x 70 . "\n";
print "Total orders attempted: " . scalar(@results) . "\n";
print "Successful: $success_count\n";
print "Failed: $fail_count\n";
print "=" x 70 . "\n";

if ($success_count > 0) {
    print "\nSuccessful Orders:\n";
    print "-" x 70 . "\n";
    foreach my $result (@results) {
        next unless $result->{success};
        print "$result->{symbol} ($result->{account})\n";
        print "  Order ID: $result->{order_id}\n";
        print "  Status: $result->{status}\n";
    }
}

if ($fail_count > 0) {
    print "\nFailed Orders:\n";
    print "-" x 70 . "\n";
    foreach my $result (@results) {
        next if $result->{success};
        print "$result->{symbol} ($result->{account})\n";
        if ($result->{error}) {
            print "  Error: $result->{error}\n";
        } else {
            print "  Status: $result->{status}\n";
        }
    }
}

print "\n" . "=" x 70 . "\n";
print "All orders have been processed.\n";
print "Note: Orders may take a few moments to execute.\n";
print "=" x 70 . "\n";