#!perl

use strict;
use warnings;
use open ':std', ':encoding(UTF-8)';

use Win32::Console; 
my $objConsole = Win32::Console->new;
$objConsole->Title('Fennel Buy');

use LWP::UserAgent;
use JSON;
use Data::Dumper;

# Configuration
my $API_BASE = "https://api.fennel.com";
my $PAT_TOKEN = '';
# $ENV{'DEBUG'} = 1;

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

sub get_latest_price {
    my ($symbol) = @_;
    my $result = api_request('POST', '/markets/prices/latest', { symbols => [$symbol] });
    return $result;
}

sub create_order {
    my ($account_id, $symbol, $shares, $side, $order_type, $limit_price, $route) = @_;
    
    # From OpenAPI spec:
    # side: BUY (1), SELL (2)
    # type: MARKET (1), LIMIT (2)
    # route: EXCHANGE (1), EXCHANGE_ATS (2), EXCHANGE_ATS_SDP (3), QUIK (4)
    # time_in_force: DAY (1)
    
    my $order_data = {
        account_id => $account_id,
        symbol => $symbol,
        shares => $shares,
        side => $side eq 'BUY' ? 1 : 2,
        type => $order_type eq 'MARKET' ? 1 : 2,
        time_in_force => 1,  # DAY
        route => $route || 1,  # Default to EXCHANGE
    };
    
    # Add limit price if it's a limit order
    if ($order_type eq 'LIMIT' && defined $limit_price) {
        $order_data->{limit_price} = $limit_price;
    }
    
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
print "Fennel Stock Purchase\n";
print "=" x 70 . "\n\n";

# Get stock symbol from user
print "Enter stock symbol (e.g., AAPL): ";
my $symbol = <STDIN>;
chomp($symbol);
$symbol = uc($symbol);  # Convert to uppercase

unless ($symbol =~ /^[A-Z0-9]+$/) {
    die "Error: Invalid stock symbol format\n";
}

print "\n";

# Get all accounts
print "Fetching your accounts...\n";
my $accounts_data = get_account_info();
my $accounts = $accounts_data->{accounts};

unless (ref($accounts) eq 'ARRAY' && @$accounts > 0) {
    die "Error: No accounts found\n";
}

# Display accounts
print "\nAvailable Accounts:\n";
print "-" x 70 . "\n";
my $account_num = 1;
foreach my $account (@$accounts) {
    my $name = $account->{name} || 'Unknown';
    my $type = get_account_type_name($account->{account_type});
    my $id = $account->{id};
    print "$account_num. $name ($type)\n";
    print "   ID: $id\n";
    $account_num++;
}
print "-" x 70 . "\n";

# Select account
my $selected_account;
if (@$accounts == 1) {
    $selected_account = $accounts->[0];
    print "\nUsing account: " . $selected_account->{name} . "\n";
} else {
    print "\nSelect account (1-" . scalar(@$accounts) . "): ";
    my $choice = <STDIN>;
    chomp($choice);
    
    unless ($choice =~ /^\d+$/ && $choice >= 1 && $choice <= @$accounts) {
        die "Error: Invalid account selection\n";
    }
    
    $selected_account = $accounts->[$choice - 1];
}

my $account_id = $selected_account->{id};
my $account_name = $selected_account->{name};

print "\n";

# Get current price
print "Fetching current price for $symbol...\n";
my $price_data;
eval {
    $price_data = get_latest_price($symbol);
};
if ($@) {
    print "Warning: Could not fetch current price: $@\n";
    print "Order will be placed at market price.\n";
}

my $current_price;
if ($price_data && $price_data->{prices} && @{$price_data->{prices}} > 0) {
    $current_price = $price_data->{prices}[0]{price};
    print "Current price: " . format_currency($current_price) . "\n";
}

print "\n";

# Confirm order
print "=" x 70 . "\n";
print "ORDER SUMMARY\n";
print "=" x 70 . "\n";
print "Account:      $account_name\n";
print "Symbol:       $symbol\n";
print "Action:       BUY\n";
print "Shares:       1\n";
print "Order Type:   MARKET\n";
if ($current_price) {
    print "Est. Cost:    " . format_currency($current_price) . " (approximate)\n";
}
print "=" x 70 . "\n";

print "\nNote: Market orders execute at the next available price.\n";
print "This may differ from the displayed estimate.\n\n";

print "Confirm order? (yes/no): ";
my $confirm = <STDIN>;
chomp($confirm);

unless (lc($confirm) eq 'yes' || lc($confirm) eq 'y') {
    print "\nOrder cancelled.\n";
    exit 0;
}

print "\n";

# Place the order
print "Placing order...\n";
my $order_result;
eval {
    $order_result = create_order(
        $account_id,
        $symbol,
        1,           # shares
        'BUY',       # side
        'MARKET',    # order_type
        undef,       # limit_price (not used for market orders)
        1            # route: EXCHANGE
    );
};

if ($@) {
    print "\n" . "=" x 70 . "\n";
    print "ERROR: Order Failed\n";
    print "=" x 70 . "\n";
    print "$@\n";
    exit 1;
}

# Display result
print "\n" . "=" x 70 . "\n";
if ($order_result->{success}) {
    print "ORDER PLACED SUCCESSFULLY\n";
    print "=" x 70 . "\n";
    print "Order ID:     $order_result->{id}\n";
    print "Status:       $order_result->{status}\n";
    print "\nYour order has been submitted and will be executed shortly.\n";
    print "Use the order ID to check the status of your order.\n";
} else {
    print "ORDER SUBMISSION FAILED\n";
    print "=" x 70 . "\n";
    print "Order ID:     $order_result->{id}\n" if $order_result->{id};
    print "Status:       $order_result->{status}\n";
}
print "=" x 70 . "\n";