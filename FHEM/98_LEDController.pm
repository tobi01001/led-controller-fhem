##############################################################################
#
# 98_LEDController.pm
#
# FHEM module for controlling LED_Stripe_Dynamic_web_conf devices
# via HTTP and WebSocket communication
#
# $Id: 98_LEDController.pm 2025-01-19 tobi01001 $
#
##############################################################################

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use IO::Socket::INET;
use Errno qw(EAGAIN EWOULDBLOCK);

sub LEDController_Initialize($);
sub LEDController_Define($$);
sub LEDController_Undef($$);
sub LEDController_Set($@);
sub LEDController_Get($@);
sub LEDController_Attr(@);
sub LEDController_SendCommand($$);
sub LEDController_ParseResponse($$);
sub LEDController_ConnectWebSocket($);
sub LEDController_ReadWebSocket($);
sub LEDController_UpdateReadingsFromWebSocket($$);

##############################################################################
# Initialize
##############################################################################
sub LEDController_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}    = "LEDController_Define";
    $hash->{UndefFn}  = "LEDController_Undef";
    $hash->{SetFn}    = "LEDController_Set";
    $hash->{GetFn}    = "LEDController_Get";
    $hash->{AttrFn}   = "LEDController_Attr";
    
    $hash->{AttrList} = "interval:1,2,3,4,5,10,15,20,30,60 " .
                        "timeout:1,2,3,4,5,10,15,20 " .
                        "disable:0,1 " .
                        "websocket:0,1 " .
                        $readingFnAttributes;
}

##############################################################################
# Define
##############################################################################
sub LEDController_Define($$) {
    my ($hash, $def) = @_;
    my @args = split("[ \t][ \t]*", $def);
    
    return "Wrong syntax: use define <name> LEDController <IP[:PORT]>" if(@args < 3);
    
    my $name = $args[0];
    my $host = $args[2];
    
    # Parse host:port
    my ($ip, $port) = split(":", $host);
    $port = 80 if(!defined($port));
    
    # Validate IP address
    return "Invalid IP address: $ip" if($ip !~ /^(\d{1,3}\.){3}\d{1,3}$/);
    
    $hash->{NAME} = $name;
    $hash->{HOST} = $ip;
    $hash->{PORT} = $port;
    $hash->{STATE} = "Initialized";
    
    # Set default attributes
    $attr{$name}{interval} = 30 if(!defined($attr{$name}{interval}));
    $attr{$name}{timeout} = 5 if(!defined($attr{$name}{timeout}));
    $attr{$name}{websocket} = 0 if(!defined($attr{$name}{websocket}));
    
    # Start timer for status updates
    InternalTimer(gettimeofday() + 2, "LEDController_GetStatus", $hash, 0);
    
    Log3 $name, 3, "LEDController ($name) - defined with host $ip:$port";
    
    return undef;
}

##############################################################################
# Undefine
##############################################################################
sub LEDController_Undef($$) {
    my ($hash, $arg) = @_;
    my $name = $hash->{NAME};
    
    # Remove timer
    RemoveInternalTimer($hash);
    
    # Remove WebSocket timer specifically
    RemoveInternalTimer($hash, "LEDController_ReadWebSocket");
    
    # Close WebSocket connection if active
    if(defined($hash->{WEBSOCKET})) {
        close($hash->{WEBSOCKET});
        delete $hash->{WEBSOCKET};
    }
    
    Log3 $name, 3, "LEDController ($name) - undefined";
    
    return undef;
}

##############################################################################
# Set
##############################################################################
sub LEDController_Set($@) {
    my ($hash, @args) = @_;
    my $name = $hash->{NAME};
    
    return "\"set $name\" needs at least one argument" if(@args < 2);
    
    my $cmd = $args[1];
    my $value = $args[2] if(defined($args[2]));
    
    Log3 $name, 4, "LEDController ($name) - set $cmd" . (defined($value) ? " $value" : "");
    
    # Check if device is disabled
    return undef if(AttrVal($name, "disable", 0) == 1);
    
    my $commands = {
        "on"         => "/on",
        "off"        => "/off",
        "brightness" => "/brightness/$value",
        "color"      => "/color/$value",
        "effect"     => "/effect/$value",
        "speed"      => "/speed/$value",
        "status"     => "/status",
        "reset"      => "/reset"
    };
    
    if($cmd eq "?") {
        return "Unknown argument $cmd, choose one of " . join(" ", sort keys %$commands);
    }
    
    if(!defined($commands->{$cmd})) {
        return "Unknown command $cmd";
    }
    
    # Validate parameters
    if($cmd eq "brightness" && (!defined($value) || $value < 0 || $value > 255)) {
        return "brightness value must be between 0 and 255";
    }
    
    if($cmd eq "color" && (!defined($value) || $value !~ /^[0-9A-Fa-f]{6}$/)) {
        return "color value must be a 6-digit hex color (e.g., FF0000)";
    }
    
    if($cmd eq "speed" && (!defined($value) || $value < 1 || $value > 100)) {
        return "speed value must be between 1 and 100";
    }
    
    # Send command
    my $url = $commands->{$cmd};
    LEDController_SendCommand($hash, $url);
    
    return undef;
}

##############################################################################
# Get
##############################################################################
sub LEDController_Get($@) {
    my ($hash, @args) = @_;
    my $name = $hash->{NAME};
    
    return "\"get $name\" needs at least one argument" if(@args < 2);
    
    my $cmd = $args[1];
    
    Log3 $name, 4, "LEDController ($name) - get $cmd";
    
    # Check if device is disabled
    return "Device is disabled" if(AttrVal($name, "disable", 0) == 1);
    
    my $gets = {
        "status"     => "/status",
        "config"     => "/config",
        "version"    => "/version"
    };
    
    if($cmd eq "?") {
        return "Unknown argument $cmd, choose one of " . join(" ", sort keys %$gets);
    }
    
    if(!defined($gets->{$cmd})) {
        return "Unknown command $cmd";
    }
    
    # Send command and return result
    return LEDController_SendCommand($hash, $gets->{$cmd});
}

##############################################################################
# Attr
##############################################################################
sub LEDController_Attr(@) {
    my ($cmd, $name, $attrName, $attrVal) = @_;
    my $hash = $defs{$name};
    
    if($cmd eq "set") {
        if($attrName eq "interval") {
            return "interval must be a positive number" if($attrVal !~ /^\d+$/ || $attrVal < 1);
            # Restart timer with new interval
            RemoveInternalTimer($hash);
            InternalTimer(gettimeofday() + $attrVal, "LEDController_GetStatus", $hash, 0);
        }
        elsif($attrName eq "timeout") {
            return "timeout must be a positive number" if($attrVal !~ /^\d+$/ || $attrVal < 1);
        }
        elsif($attrName eq "websocket") {
            if($attrVal == 1) {
                LEDController_ConnectWebSocket($hash);
            } elsif($attrVal == 0 && defined($hash->{WEBSOCKET})) {
                close($hash->{WEBSOCKET});
                delete $hash->{WEBSOCKET};
            }
        }
    }
    
    return undef;
}

##############################################################################
# Send HTTP Command
##############################################################################
sub LEDController_SendCommand($$) {
    my ($hash, $url) = @_;
    my $name = $hash->{NAME};
    my $host = $hash->{HOST};
    my $port = $hash->{PORT};
    my $timeout = AttrVal($name, "timeout", 5);
    
    my $param = {
        url        => "http://$host:$port$url",
        timeout    => $timeout,
        hash       => $hash,
        method     => "GET",
        callback   => \&LEDController_ParseResponse
    };
    
    Log3 $name, 4, "LEDController ($name) - sending command: $url";
    
    HttpUtils_NonblockingGet($param);
    
    return undef;
}

##############################################################################
# Parse HTTP Response
##############################################################################
sub LEDController_ParseResponse($$) {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    
    if($err ne "") {
        Log3 $name, 2, "LEDController ($name) - error: $err";
        readingsSingleUpdate($hash, "state", "error", 1);
        return;
    }
    
    Log3 $name, 4, "LEDController ($name) - received response: $data";
    
    # Try to parse JSON response
    my $json;
    eval {
        $json = decode_json($data);
    };
    
    if($@) {
        Log3 $name, 3, "LEDController ($name) - invalid JSON response: $data";
        return;
    }
    
    # Update readings based on response
    readingsBeginUpdate($hash);
    
    if(defined($json->{state})) {
        readingsBulkUpdate($hash, "state", $json->{state});
    }
    
    if(defined($json->{brightness})) {
        readingsBulkUpdate($hash, "brightness", $json->{brightness});
    }
    
    if(defined($json->{color})) {
        readingsBulkUpdate($hash, "color", $json->{color});
    }
    
    if(defined($json->{effect})) {
        readingsBulkUpdate($hash, "effect", $json->{effect});
    }
    
    if(defined($json->{speed})) {
        readingsBulkUpdate($hash, "speed", $json->{speed});
    }
    
    readingsEndUpdate($hash, 1);
    
    # Schedule next status update
    my $interval = AttrVal($name, "interval", 30);
    InternalTimer(gettimeofday() + $interval, "LEDController_GetStatus", $hash, 0);
}

##############################################################################
# Get Status (Timer Function)
##############################################################################
sub LEDController_GetStatus($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    return if(AttrVal($name, "disable", 0) == 1);
    
    LEDController_SendCommand($hash, "/status");
}

##############################################################################
# Connect WebSocket (Optional Feature)
##############################################################################
sub LEDController_ConnectWebSocket($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $host = $hash->{HOST};
    my $port = $hash->{PORT};
    
    Log3 $name, 3, "LEDController ($name) - connecting WebSocket to $host:$port";
    
    # Basic WebSocket implementation using IO::Socket::INET
    # This assumes the LED controller provides a WebSocket endpoint on /ws
    eval {
        my $socket = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => AttrVal($name, "timeout", 5)
        );
        
        if($socket) {
            # Send WebSocket handshake
            my $handshake = "GET /ws HTTP/1.1\r\n" .
                           "Host: $host:$port\r\n" .
                           "Upgrade: websocket\r\n" .
                           "Connection: Upgrade\r\n" .
                           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" .
                           "Sec-WebSocket-Version: 13\r\n\r\n";
            
            print $socket $handshake;
            
            # Read response (basic validation)
            my $response = <$socket>;
            if($response && $response =~ /HTTP\/1\.1 101/) {
                $hash->{WEBSOCKET} = $socket;
                Log3 $name, 3, "LEDController ($name) - WebSocket connected successfully";
                
                # Set non-blocking mode for receiving updates
                $socket->blocking(0);
                
                # Start WebSocket reader
                InternalTimer(gettimeofday() + 1, "LEDController_ReadWebSocket", $hash, 0);
            } else {
                Log3 $name, 2, "LEDController ($name) - WebSocket handshake failed";
                close($socket);
            }
        } else {
            Log3 $name, 2, "LEDController ($name) - Could not connect to WebSocket: $!";
        }
    };
    
    if($@) {
        Log3 $name, 2, "LEDController ($name) - WebSocket connection error: $@";
    }
    
    return undef;
}

##############################################################################
# Read WebSocket Data
##############################################################################
sub LEDController_ReadWebSocket($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    return unless defined($hash->{WEBSOCKET});
    
    my $socket = $hash->{WEBSOCKET};
    my $data = "";
    
    # Try to read data (non-blocking)
    my $bytes_read = sysread($socket, $data, 1024);
    
    if(defined($bytes_read) && $bytes_read > 0) {
        Log3 $name, 4, "LEDController ($name) - WebSocket data received: $data";
        
        # Basic WebSocket frame parsing (simplified)
        # In a real implementation, you'd want proper frame parsing
        if($data =~ /\{.*\}/) {
            # Extract JSON payload
            if($data =~ /(\{.*\})/) {
                my $json_data = $1;
                eval {
                    my $json = decode_json($json_data);
                    LEDController_UpdateReadingsFromWebSocket($hash, $json);
                };
                if($@) {
                    Log3 $name, 3, "LEDController ($name) - WebSocket JSON parse error: $@";
                }
            }
        }
    } elsif(!defined($bytes_read) && $! != EAGAIN && $! != EWOULDBLOCK) {
        # Connection lost
        Log3 $name, 2, "LEDController ($name) - WebSocket connection lost";
        close($hash->{WEBSOCKET});
        delete $hash->{WEBSOCKET};
        return;
    }
    
    # Schedule next read
    InternalTimer(gettimeofday() + 1, "LEDController_ReadWebSocket", $hash, 0);
}

##############################################################################
# Update Readings from WebSocket
##############################################################################
sub LEDController_UpdateReadingsFromWebSocket($$) {
    my ($hash, $json) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 4, "LEDController ($name) - Updating readings from WebSocket";
    
    readingsBeginUpdate($hash);
    
    if(defined($json->{state})) {
        readingsBulkUpdate($hash, "state", $json->{state});
    }
    
    if(defined($json->{brightness})) {
        readingsBulkUpdate($hash, "brightness", $json->{brightness});
    }
    
    if(defined($json->{color})) {
        readingsBulkUpdate($hash, "color", $json->{color});
    }
    
    if(defined($json->{effect})) {
        readingsBulkUpdate($hash, "effect", $json->{effect});
    }
    
    if(defined($json->{speed})) {
        readingsBulkUpdate($hash, "speed", $json->{speed});
    }
    
    readingsBulkUpdate($hash, "last_websocket_update", time());
    readingsEndUpdate($hash, 1);
}

1;

=pod
=item device
=item summary FHEM module for LED_Stripe_Dynamic_web_conf controllers
=begin html

<a name="LEDController"></a>
<h3>LEDController</h3>
<ul>
  <p>FHEM module for controlling LED_Stripe_Dynamic_web_conf devices via HTTP and WebSocket.</p>
  
  <a name="LEDControllerdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; LEDController &lt;IP[:PORT]&gt;</code>
    <br><br>
    Example: <code>define myLED LEDController 192.168.1.100:80</code>
  </ul>
  <br>
  
  <a name="LEDControllerset"></a>
  <b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; on</code> - Turn LED strip on</li>
    <li><code>set &lt;name&gt; off</code> - Turn LED strip off</li>
    <li><code>set &lt;name&gt; brightness &lt;0-255&gt;</code> - Set brightness</li>
    <li><code>set &lt;name&gt; color &lt;RRGGBB&gt;</code> - Set color (hex format)</li>
    <li><code>set &lt;name&gt; effect &lt;effect_name&gt;</code> - Set effect</li>
    <li><code>set &lt;name&gt; speed &lt;1-100&gt;</code> - Set effect speed</li>
    <li><code>set &lt;name&gt; reset</code> - Reset to default settings</li>
  </ul>
  <br>
  
  <a name="LEDControllerget"></a>
  <b>Get</b>
  <ul>
    <li><code>get &lt;name&gt; status</code> - Get current status</li>
    <li><code>get &lt;name&gt; config</code> - Get configuration</li>
    <li><code>get &lt;name&gt; version</code> - Get firmware version</li>
  </ul>
  <br>
  
  <a name="LEDControllerattr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>interval</code> - Status update interval in seconds (default: 30)</li>
    <li><code>timeout</code> - HTTP timeout in seconds (default: 5)</li>
    <li><code>disable</code> - Disable device (0/1, default: 0)</li>
    <li><code>websocket</code> - Enable WebSocket connection (0/1, default: 0)</li>
  </ul>
</ul>

=end html
=cut