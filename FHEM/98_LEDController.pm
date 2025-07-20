##############################################################################
#
# 98_LEDController.pm
#
# FHEM module for controlling LED_Stripe_Dynamic_web_conf devices
# via HTTP and WebSocket communication with dynamic field structure
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

# Field types from LED_Stripe_Dynamic_web_conf backend
use constant {
    NumberFieldType  => 0,
    BooleanFieldType => 1,
    SelectFieldType  => 2,
    ColorFieldType   => 3,
    TitleFieldType   => 4,
    SectionFieldType => 5,
    InvalidFieldType => 6
};

sub LEDController_Initialize($);
sub LEDController_Define($$);
sub LEDController_Undef($$);
sub LEDController_Set($@);
sub LEDController_Get($@);
sub LEDController_Attr(@);
sub LEDController_SendCommand($$;$);
sub LEDController_ParseResponse($$);
sub LEDController_ConnectWebSocket($);
sub LEDController_ReadWebSocket($);
sub LEDController_ParseWebSocketFrame($);
sub LEDController_UpdateReadingsFromWebSocket($$);
sub LEDController_GetFieldStructure($);
sub LEDController_BuildDynamicCommands($);
sub LEDController_ValidateFieldValue($$$);
sub LEDController_FormatFieldValue($$);
sub LEDController_ParseFieldStructure($$);
sub LEDController_BuildFHEMControls($);
sub LEDController_BuildWebCmd($);
sub LEDController_BuildWidgetOverrides($);

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
                        "sections:textField-long " .
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
    $hash->{STATE} = "Initializing";
    
    # Initialize field structure storage
    $hash->{FIELD_STRUCTURE} = {};
    $hash->{FIELD_SECTIONS} = [];
    $hash->{DYNAMIC_COMMANDS} = {};
    
    # Set default attributes
    $attr{$name}{interval} = 30 if(!defined($attr{$name}{interval}));
    $attr{$name}{timeout} = 5 if(!defined($attr{$name}{timeout}));
    $attr{$name}{websocket} = 0 if(!defined($attr{$name}{websocket}));
    
    # Get field structure from device
    InternalTimer(gettimeofday() + 2, "LEDController_GetFieldStructure", $hash, 0);
    
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
    
    # Build help text from dynamic commands
    if($cmd eq "?") {
        my $helpText = "Unknown argument $cmd, choose one of ";
        
        if(keys %{$hash->{DYNAMIC_COMMANDS}} > 0) {
            $helpText .= join(" ", sort keys %{$hash->{DYNAMIC_COMMANDS}});
        } else {
            $helpText .= "refresh";
        }
        
        return $helpText;
    }
    
    # Handle refresh command to reload field structure
    if($cmd eq "refresh") {
        LEDController_GetFieldStructure($hash);
        return "Field structure refresh initiated";
    }
    
    # Check if command exists in dynamic commands
    if(!defined($hash->{DYNAMIC_COMMANDS}->{$cmd})) {
        return "Unknown command $cmd. Use 'refresh' to reload available commands.";
    }
    
    my $fieldInfo = $hash->{DYNAMIC_COMMANDS}->{$cmd};
    
    # Validate field value
    my $validationResult = LEDController_ValidateFieldValue($fieldInfo, $value, $name);
    return $validationResult if($validationResult);
    
    # Format value for the LED controller
    my $formattedValue = LEDController_FormatFieldValue($fieldInfo, $value);
    
    # Send command using /set endpoint with query parameters
    my $url = "/set?" . $fieldInfo->{name} . "=" . $formattedValue;
    
    # Handle special color field case
    if($fieldInfo->{type} == ColorFieldType && $value =~ /^([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})$/) {
        my ($r, $g, $b) = (hex($1), hex($2), hex($3));
        $url = "/set?" . $fieldInfo->{name} . "=solidColor&r=$r&g=$g&b=$b";
    }
    
    Log3 $name, 4, "LEDController ($name) - sending: $url";
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
        "status"      => "/status",
        "allvalues"   => "/allvalues",
        "structure"   => "/all",
        "modes"       => "/getmodes",
        "palettes"    => "/getpals"
    };
    
    if($cmd eq "?") {
        return "Unknown argument $cmd, choose one of " . join(" ", sort keys %$gets);
    }
    
    if(!defined($gets->{$cmd})) {
        return "Unknown command $cmd";
    }
    
    # Send command and return result
    return LEDController_SendCommand($hash, $gets->{$cmd}, 1);
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
                readingsSingleUpdate($hash, "websocket_connection", "disconnected", 1);
            }
        }
    }
    
    return undef;
}

##############################################################################
# Send HTTP Command
##############################################################################
sub LEDController_SendCommand($$;$) {
    my ($hash, $url, $returnResult) = @_;
    my $name = $hash->{NAME};
    my $host = $hash->{HOST};
    my $port = $hash->{PORT};
    my $timeout = AttrVal($name, "timeout", 5);
    
    my $param = {
        url          => "http://$host:$port$url",
        timeout      => $timeout,
        hash         => $hash,
        method       => "GET",
        returnResult => $returnResult || 0,
        callback     => \&LEDController_ParseResponse
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
    my $returnResult = $param->{returnResult} || 0;
    
    if($err ne "") {
        Log3 $name, 2, "LEDController ($name) - error: $err";
        readingsSingleUpdate($hash, "state", "error", 1);
        return $returnResult ? "Error: $err" : undef;
    }
    
    Log3 $name, 4, "LEDController ($name) - received response: " . substr($data, 0, 200);
    
    # Return raw data for get commands
    if($returnResult) {
        return $data;
    }
    
    # Handle different response types
    my $url = $param->{url};
    
    if($url =~ /\/all$/) {
        LEDController_ParseFieldStructure($hash, $data);
        return;
    }
    
    if($url =~ /\/allvalues$/) {
        LEDController_UpdateAllReadings($hash, $data);
        return;
    }
    
    # Try to parse JSON response
    my $json;
    eval {
        $json = decode_json($data);
    };
    
    if($@) {
        Log3 $name, 3, "LEDController ($name) - invalid JSON response: " . substr($data, 0, 100);
        return;
    }
    
    # Update readings based on response
    readingsBeginUpdate($hash);
    
    # Handle different response structures
    if(defined($json->{currentState})) {
        # Response from /set endpoint
        LEDController_UpdateReadingsFromJSON($hash, $json->{currentState});
    } elsif(defined($json->{power})) {
        # Direct field responses
        LEDController_UpdateReadingsFromJSON($hash, $json);
    }
    
    readingsBulkUpdate($hash, "state", "active");
    readingsBulkUpdate($hash, "lastUpdate", time());
    readingsEndUpdate($hash, 1);
    
    # Schedule next status update if this was a status request
    if($url =~ /\/status$/) {
        my $interval = AttrVal($name, "interval", 30);
        InternalTimer(gettimeofday() + $interval, "LEDController_GetStatus", $hash, 0);
    }
}

##############################################################################
# Get Status (Timer Function)
##############################################################################
sub LEDController_GetStatus($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    return if(AttrVal($name, "disable", 0) == 1);
    
    # Get current values using /allvalues endpoint
    LEDController_SendCommand($hash, "/allvalues");
}

##############################################################################
# Get Field Structure from Device
##############################################################################
sub LEDController_GetFieldStructure($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 3, "LEDController ($name) - retrieving field structure from device";
    
    # Request field structure from /all endpoint
    LEDController_SendCommand($hash, "/all");
}

##############################################################################
# Parse Field Structure Response
##############################################################################
sub LEDController_ParseFieldStructure($$) {
    my ($hash, $data) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 4, "LEDController ($name) - parsing field structure";
    
    my $fields;
    eval {
        $fields = decode_json($data);
    };
    
    if($@) {
        Log3 $name, 2, "LEDController ($name) - error parsing field structure: $@";
        $hash->{STATE} = "Error parsing structure";
        return;
    }
    
    # Store field structure
    $hash->{FIELD_STRUCTURE} = {};
    $hash->{FIELD_SECTIONS} = [];
    
    my $currentSection = "default";
    my @sections = ();
    
    foreach my $field (@$fields) {
        next unless ref($field) eq 'HASH';
        
        my $fieldName = $field->{name} || "";
        my $fieldType = $field->{type};
        
        # Track sections
        if(defined($fieldType) && $fieldType == SectionFieldType) {
            $currentSection = $fieldName;
            push @sections, {
                name => $fieldName,
                label => $field->{label} || $fieldName
            };
            next;
        }
        
        # Skip title fields for commands
        next if(defined($fieldType) && $fieldType == TitleFieldType);
        
        # Store field information
        if($fieldName ne "") {
            $field->{section} = $currentSection;
            $hash->{FIELD_STRUCTURE}->{$fieldName} = $field;
        }
    }
    
    $hash->{FIELD_SECTIONS} = \@sections;
    
    # Build dynamic commands
    LEDController_BuildDynamicCommands($hash);
    
    # Build FHEM control elements
    LEDController_BuildFHEMControls($hash);
    
    # Start regular status updates
    $hash->{STATE} = "active";
    InternalTimer(gettimeofday() + 5, "LEDController_GetStatus", $hash, 0);
    
    Log3 $name, 3, "LEDController ($name) - field structure loaded with " . 
                   scalar(keys %{$hash->{FIELD_STRUCTURE}}) . " fields";
}

##############################################################################
# Build Dynamic Commands from Field Structure
##############################################################################
sub LEDController_BuildDynamicCommands($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    $hash->{DYNAMIC_COMMANDS} = {};
    
    foreach my $fieldName (keys %{$hash->{FIELD_STRUCTURE}}) {
        my $field = $hash->{FIELD_STRUCTURE}->{$fieldName};
        my $fieldType = $field->{type};
        
        # Skip non-settable fields
        next if(!defined($fieldType));
        next if($fieldType == TitleFieldType || $fieldType == SectionFieldType);
        
        # Create command name (convert camelCase to underscore)
        my $cmdName = $fieldName;
        $cmdName =~ s/([a-z])([A-Z])/$1_$2/g;
        $cmdName = lc($cmdName);
        
        # Store command mapping
        $hash->{DYNAMIC_COMMANDS}->{$cmdName} = $field;
        
        # Create readable command variations
        if($fieldType == BooleanFieldType) {
            # Create on/off variants for boolean fields
            if($fieldName eq "power") {
                $hash->{DYNAMIC_COMMANDS}->{"on"} = $field;
                $hash->{DYNAMIC_COMMANDS}->{"off"} = $field;
            }
        }
    }
    
    Log3 $name, 3, "LEDController ($name) - built " . 
                   scalar(keys %{$hash->{DYNAMIC_COMMANDS}}) . " dynamic commands";
}

##############################################################################
# Validate Field Value
##############################################################################
sub LEDController_ValidateFieldValue($$$) {
    my ($fieldInfo, $value, $name) = @_;
    
    my $fieldType = $fieldInfo->{type};
    my $fieldName = $fieldInfo->{name};
    
    if($fieldType == NumberFieldType) {
        return "Value required for numeric field $fieldName" if(!defined($value));
        return "Invalid numeric value for $fieldName" if($value !~ /^\d+$/);
        
        my $min = $fieldInfo->{min} || 0;
        my $max = $fieldInfo->{max} || 65535;
        return "Value for $fieldName must be between $min and $max" if($value < $min || $value > $max);
    }
    elsif($fieldType == BooleanFieldType) {
        if(defined($value)) {
            return "Boolean value must be 0, 1, on, or off" if($value !~ /^(0|1|on|off)$/i);
        }
    }
    elsif($fieldType == SelectFieldType) {
        return "Value required for select field $fieldName" if(!defined($value));
        return "Invalid numeric value for select $fieldName" if($value !~ /^\d+$/);
        
        my $max = $fieldInfo->{max} || 0;
        return "Select value for $fieldName must be between 0 and $max" if($value > $max);
    }
    elsif($fieldType == ColorFieldType) {
        return "Color value required" if(!defined($value));
        return "Color value must be 6-digit hex (RRGGBB)" if($value !~ /^[0-9A-Fa-f]{6}$/);
    }
    
    return undef; # No error
}

##############################################################################
# Format Field Value for LED Controller
##############################################################################
sub LEDController_FormatFieldValue($$) {
    my ($fieldInfo, $value) = @_;
    
    my $fieldType = $fieldInfo->{type};
    my $fieldName = $fieldInfo->{name};
    
    if($fieldType == BooleanFieldType) {
        # Handle special cases for boolean fields
        if($fieldName eq "power") {
            return 1 if(!defined($value) || $value eq "on");
            return 0 if($value eq "off");
        }
        
        return 1 if(!defined($value) || $value eq "on" || $value eq "1");
        return 0;
    }
    elsif($fieldType == ColorFieldType) {
        # Convert hex color to decimal
        return hex($value);
    }
    
    return $value || 0;
}

##############################################################################
# Update All Readings from /allvalues Response
##############################################################################
sub LEDController_UpdateAllReadings($$) {
    my ($hash, $data) = @_;
    my $name = $hash->{NAME};
    
    my $json;
    eval {
        $json = decode_json($data);
    };
    
    if($@) {
        Log3 $name, 3, "LEDController ($name) - error parsing allvalues response: $@";
        return;
    }
    
    readingsBeginUpdate($hash);
    
    if(defined($json->{values}) && ref($json->{values}) eq 'ARRAY') {
        foreach my $valueItem (@{$json->{values}}) {
            next unless ref($valueItem) eq 'HASH';
            next unless defined($valueItem->{name}) && defined($valueItem->{value});
            
            my $readingName = $valueItem->{name};
            my $readingValue = $valueItem->{value};
            
            # Format reading value based on field type
            if(defined($hash->{FIELD_STRUCTURE}->{$readingName})) {
                my $field = $hash->{FIELD_STRUCTURE}->{$readingName};
                my $fieldType = $field->{type};
                
                if($fieldType == BooleanFieldType) {
                    $readingValue = $readingValue ? "on" : "off";
                }
                elsif($fieldType == SelectFieldType && defined($field->{options})) {
                    # Would need to get options from field definition
                    # For now, keep numeric value
                }
                elsif($fieldType == ColorFieldType) {
                    $readingValue = sprintf("%06X", $readingValue);
                }
            }
            
            readingsBulkUpdate($hash, $readingName, $readingValue);
            
            # Update STATE based on power reading
            if($readingName eq "power") {
                my $state = $readingValue eq "on" ? "on" : "off";
                readingsBulkUpdate($hash, "state", $state);
            }
        }
    }
    
    readingsBulkUpdate($hash, "state", "active");
    readingsBulkUpdate($hash, "lastUpdate", time());
    readingsEndUpdate($hash, 1);
}

##############################################################################
# Update Readings from JSON Response
##############################################################################
sub LEDController_UpdateReadingsFromJSON($$) {
    my ($hash, $json) = @_;
    
    foreach my $key (keys %$json) {
        next if($key eq "state"); # Handle state separately
        
        my $value = $json->{$key};
        
        # Format value based on field type if known
        if(defined($hash->{FIELD_STRUCTURE}->{$key})) {
            my $field = $hash->{FIELD_STRUCTURE}->{$key};
            my $fieldType = $field->{type};
            
            if($fieldType == BooleanFieldType) {
                $value = $value ? "on" : "off";
            }
            elsif($fieldType == ColorFieldType) {
                $value = sprintf("%06X", $value) if($value =~ /^\d+$/);
            }
        }
        
        readingsBulkUpdate($hash, $key, $value);
        
        # Update STATE based on power reading
        if($key eq "power") {
            my $state = $value eq "on" ? "on" : "off";
            readingsBulkUpdate($hash, "state", $state);
        }
    }
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
    
    # Set WebSocket connection status to connecting
    readingsSingleUpdate($hash, "websocket_connection", "connecting", 1);
    
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
                readingsSingleUpdate($hash, "websocket_connection", "connected", 1);
                Log3 $name, 3, "LEDController ($name) - WebSocket connected successfully";
                
                # Set non-blocking mode for receiving updates
                $socket->blocking(0);
                
                # Start WebSocket reader
                InternalTimer(gettimeofday() + 1, "LEDController_ReadWebSocket", $hash, 0);
            } else {
                readingsSingleUpdate($hash, "websocket_connection", "failed", 1);
                Log3 $name, 2, "LEDController ($name) - WebSocket handshake failed";
                close($socket);
            }
        } else {
            readingsSingleUpdate($hash, "websocket_connection", "failed", 1);
            Log3 $name, 2, "LEDController ($name) - Could not connect to WebSocket: $!";
        }
    };
    
    if($@) {
        readingsSingleUpdate($hash, "websocket_connection", "failed", 1);
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
        
        # Parse WebSocket frames and extract JSON objects
        my @json_objects = LEDController_ParseWebSocketFrame($data);
        
        foreach my $json (@json_objects) {
            eval {
                LEDController_UpdateReadingsFromWebSocket($hash, $json);
            };
            if($@) {
                Log3 $name, 3, "LEDController ($name) - WebSocket JSON processing error: $@";
            }
        }
    } elsif(!defined($bytes_read) && $! != EAGAIN && $! != EWOULDBLOCK) {
        # Connection lost
        readingsSingleUpdate($hash, "websocket_connection", "disconnected", 1);
        Log3 $name, 2, "LEDController ($name) - WebSocket connection lost";
        close($hash->{WEBSOCKET});
        delete $hash->{WEBSOCKET};
        return;
    }
    
    # Schedule next read
    InternalTimer(gettimeofday() + 1, "LEDController_ReadWebSocket", $hash, 0);
}

##############################################################################
# Parse WebSocket Frame and Extract JSON Objects
##############################################################################
sub LEDController_ParseWebSocketFrame($) {
    my ($data) = @_;
    my @json_objects = ();
    
    # Remove WebSocket frame headers and control bytes
    # WebSocket text frame starts with 0x81, followed by payload length
    if (length($data) >= 2) {
        my $first_byte = ord(substr($data, 0, 1));
        
        # Check if this is a WebSocket text frame (0x81)
        if ($first_byte == 0x81) {
            my $second_byte = ord(substr($data, 1, 1));
            my $payload_start = 2;
            my $payload_length = $second_byte & 0x7F;
            
            # Handle extended payload length
            if ($payload_length == 126) {
                $payload_start = 4;
                $payload_length = unpack('n', substr($data, 2, 2));
            } elsif ($payload_length == 127) {
                $payload_start = 10;
                $payload_length = unpack('Q>', substr($data, 2, 8));
            }
            
            # Extract payload if we have enough data
            if (length($data) >= $payload_start + $payload_length) {
                $data = substr($data, $payload_start, $payload_length);
            }
        }
    }
    
    # Clean up any remaining control characters except valid JSON characters
    # Keep printable ASCII and common whitespace, remove other control chars
    $data =~ s/[\x00-\x1F\x7F-\xFF]//g unless $data =~ /^[\x20-\x7E\s]*$/;
    
    # Find all JSON objects in the cleaned data
    my $pos = 0;
    while ($pos < length($data)) {
        # Find start of JSON object
        my $start = index($data, '{', $pos);
        last if $start == -1;
        
        # Find matching closing brace
        my $brace_count = 0;
        my $end = $start;
        for my $i ($start..length($data)-1) {
            my $char = substr($data, $i, 1);
            if ($char eq '{') {
                $brace_count++;
            } elsif ($char eq '}') {
                $brace_count--;
                if ($brace_count == 0) {
                    $end = $i;
                    last;
                }
            }
        }
        
        # If we found a complete JSON object, try to parse it
        if ($brace_count == 0) {
            my $json_str = substr($data, $start, $end - $start + 1);
            eval {
                my $json = decode_json($json_str);
                push @json_objects, $json;
            };
            # Silently skip invalid JSON - errors will be logged by caller if needed
        }
        
        $pos = $end + 1;
    }
    
    return @json_objects;
}

##############################################################################
# Update Readings from WebSocket
##############################################################################
sub LEDController_UpdateReadingsFromWebSocket($$) {
    my ($hash, $json) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 4, "LEDController ($name) - Updating readings from WebSocket";
    
    readingsBeginUpdate($hash);
    
    # Handle WebSocket message format: {"name": "field_name", "value": field_value}
    if(defined($json->{name}) && defined($json->{value})) {
        my $fieldName = $json->{name};
        my $fieldValue = $json->{value};
        
        # Format value based on field type
        if(defined($hash->{FIELD_STRUCTURE}->{$fieldName})) {
            my $field = $hash->{FIELD_STRUCTURE}->{$fieldName};
            my $fieldType = $field->{type};
            
            if($fieldType == BooleanFieldType) {
                $fieldValue = $fieldValue ? "on" : "off";
            }
            elsif($fieldType == ColorFieldType) {
                $fieldValue = sprintf("%06X", $fieldValue) if($fieldValue =~ /^\d+$/);
            }
        }
        
        readingsBulkUpdate($hash, $fieldName, $fieldValue);
        
        # Update STATE based on power reading
        if($fieldName eq "power") {
            my $state = $fieldValue eq "on" ? "on" : "off";
            readingsBulkUpdate($hash, "state", $state);
        }
    }
    else {
        # Handle other JSON structures
        LEDController_UpdateReadingsFromJSON($hash, $json);
    }
    
    readingsBulkUpdate($hash, "last_websocket_update", time());
    readingsEndUpdate($hash, 1);
}

##############################################################################
# Build FHEM Control Elements 
##############################################################################
sub LEDController_BuildFHEMControls($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 3, "LEDController ($name) - building FHEM control elements";
    
    # Build webCmd attribute
    my $webCmd = LEDController_BuildWebCmd($hash);
    if($webCmd) {
        $attr{$name}{webCmd} = $webCmd;
        Log3 $name, 4, "LEDController ($name) - set webCmd: $webCmd";
    }
    
    # Build widgetOverride attribute  
    my $widgetOverrides = LEDController_BuildWidgetOverrides($hash);
    if($widgetOverrides) {
        $attr{$name}{widgetOverride} = $widgetOverrides;
        Log3 $name, 4, "LEDController ($name) - set widgetOverride: $widgetOverrides";
    }
    
    Log3 $name, 3, "LEDController ($name) - FHEM control elements built successfully";
}

##############################################################################
# Build WebCmd Attribute
##############################################################################
sub LEDController_BuildWebCmd($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    my @webCmds = ();
    
    # Always add refresh command
    push @webCmds, "refresh";
    
    # Process fields in a predictable order
    my @sortedFields = sort keys %{$hash->{FIELD_STRUCTURE}};
    
    foreach my $fieldName (@sortedFields) {
        my $field = $hash->{FIELD_STRUCTURE}->{$fieldName};
        my $fieldType = $field->{type};
        
        # Skip non-settable fields
        next if(!defined($fieldType));
        next if($fieldType == TitleFieldType || $fieldType == SectionFieldType);
        
        # Convert field name to command name
        my $cmdName = $fieldName;
        $cmdName =~ s/([a-z])([A-Z])/$1_$2/g;
        $cmdName = lc($cmdName);
        
        # Build command based on field type
        if($fieldType == BooleanFieldType) {
            if($fieldName eq "power") {
                # Special case for power: add on/off commands
                push @webCmds, "on", "off";
            } else {
                # For other boolean fields, add the field with on/off options
                push @webCmds, "$cmdName:on,off";
            }
        }
        elsif($fieldType == NumberFieldType) {
            my $min = $field->{min} || 0;
            my $max = $field->{max} || 255;
            push @webCmds, "$cmdName:slider,$min,1,$max";
        }
        elsif($fieldType == SelectFieldType) {
            my $max = $field->{max} || 0;
            my @options = ();
            
            # If options are available, use them
            if(defined($field->{options}) && ref($field->{options}) eq 'ARRAY') {
                for my $i (0..$#{$field->{options}}) {
                    push @options, "$i," . $field->{options}->[$i];
                }
            } else {
                # Generate numbered options
                for my $i (0..$max) {
                    push @options, "$i,Option$i";
                }
            }
            
            if(@options > 0) {
                push @webCmds, "$cmdName:" . join(",", @options);
            }
        }
        elsif($fieldType == ColorFieldType) {
            push @webCmds, "$cmdName:colorpicker,RGB";
        }
    }
    
    return join(" ", @webCmds);
}

##############################################################################
# Build WidgetOverride Attribute
##############################################################################
sub LEDController_BuildWidgetOverrides($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    my @overrides = ();
    
    # Process fields for widget overrides
    foreach my $fieldName (sort keys %{$hash->{FIELD_STRUCTURE}}) {
        my $field = $hash->{FIELD_STRUCTURE}->{$fieldName};
        my $fieldType = $field->{type};
        
        # Skip non-settable fields
        next if(!defined($fieldType));
        next if($fieldType == TitleFieldType || $fieldType == SectionFieldType);
        
        # Convert field name to command name  
        my $cmdName = $fieldName;
        $cmdName =~ s/([a-z])([A-Z])/$1_$2/g;
        $cmdName = lc($cmdName);
        
        # Add widget overrides based on field type
        if($fieldType == NumberFieldType) {
            my $min = $field->{min} || 0;
            my $max = $field->{max} || 255;
            my $label = $field->{label} || $fieldName;
            
            push @overrides, "$cmdName:slider,$min,$max,1";
        }
        elsif($fieldType == BooleanFieldType && $fieldName ne "power") {
            my $label = $field->{label} || $fieldName;
            push @overrides, "$cmdName:uzsuToggle,off,on";
        }
        elsif($fieldType == SelectFieldType) {
            my $label = $field->{label} || $fieldName;
            if(defined($field->{options}) && ref($field->{options}) eq 'ARRAY') {
                my @options = @{$field->{options}};
                push @overrides, "$cmdName:selectnumbers," . join(",", @options);
            }
        }
        elsif($fieldType == ColorFieldType) {
            my $label = $field->{label} || $fieldName;
            push @overrides, "$cmdName:colorpicker";
        }
    }
    
    return join(" ", @overrides) if @overrides;
    return "";
}

1;

=pod
=item device
=item summary FHEM module for LED_Stripe_Dynamic_web_conf controllers with dynamic field structure
=begin html

<a name="LEDController"></a>
<h3>LEDController</h3>
<ul>
  <p>FHEM module for controlling LED_Stripe_Dynamic_web_conf devices via HTTP and WebSocket.</p>
  <p>This module automatically discovers the device capabilities and builds dynamic commands 
     based on the field structure provided by the LED controller.</p>
  
  <a name="LEDControllerdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; LEDController &lt;IP[:PORT]&gt;</code>
    <br><br>
    Example: <code>define myLED LEDController 192.168.1.100:80</code>
    <br><br>
    The module will automatically connect to the device and discover available fields and commands.
  </ul>
  <br>
  
  <a name="LEDControllerset"></a>
  <b>Set</b>
  <ul>
    <p>Commands are dynamically generated based on the device capabilities. Common commands include:</p>
    <li><code>set &lt;name&gt; power on|off</code> - Power control</li>
    <li><code>set &lt;name&gt; on</code> - Turn on (alias for power on)</li>
    <li><code>set &lt;name&gt; off</code> - Turn off (alias for power off)</li>
    <li><code>set &lt;name&gt; brightness &lt;0-255&gt;</code> - Set brightness</li>
    <li><code>set &lt;name&gt; effect &lt;0-N&gt;</code> - Set effect (number)</li>
    <li><code>set &lt;name&gt; speed &lt;value&gt;</code> - Set effect speed</li>
    <li><code>set &lt;name&gt; color_palette &lt;0-N&gt;</code> - Set color palette</li>
    <li><code>set &lt;name&gt; solid_color &lt;RRGGBB&gt;</code> - Set solid color (hex format)</li>
    <li><code>set &lt;name&gt; auto_play &lt;mode&gt;</code> - Set auto mode change</li>
    <li><code>set &lt;name&gt; refresh</code> - Reload field structure from device</li>
    <br>
    <p>Use <code>set &lt;name&gt; ?</code> to see all available commands for your specific device.</p>
  </ul>
  <br>
  
  <a name="LEDControllerget"></a>
  <b>Get</b>
  <ul>
    <li><code>get &lt;name&gt; status</code> - Get detailed device status</li>
    <li><code>get &lt;name&gt; allvalues</code> - Get all current field values</li>
    <li><code>get &lt;name&gt; structure</code> - Get field structure (raw JSON)</li>
    <li><code>get &lt;name&gt; modes</code> - Get available effects/modes</li>
    <li><code>get &lt;name&gt; palettes</code> - Get available color palettes</li>
  </ul>
  <br>
  
  <a name="LEDControllerattr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>interval</code> - Status update interval in seconds (default: 30)</li>
    <li><code>timeout</code> - HTTP timeout in seconds (default: 5)</li>
    <li><code>disable</code> - Disable device (0/1, default: 0)</li>
    <li><code>websocket</code> - Enable WebSocket connection for real-time updates (0/1, default: 0)</li>
    <li><code>sections</code> - Comma-separated list of sections to show (optional)</li>
  </ul>
  <br>
  
  <a name="LEDControllerreadings"></a>
  <b>Readings</b>
  <ul>
    <p>Readings are dynamically created based on the device field structure. Common readings include:</p>
    <li><code>power</code> - Power state (on/off)</li>
    <li><code>brightness</code> - Current brightness (0-255)</li>
    <li><code>effect</code> - Current effect number</li>
    <li><code>speed</code> - Current effect speed</li>
    <li><code>colorPalette</code> - Current color palette</li>
    <li><code>solidColor</code> - Current solid color (hex)</li>
    <li><code>state</code> - Module state</li>
    <li><code>lastUpdate</code> - Timestamp of last update</li>
    <li><code>last_websocket_update</code> - Timestamp of last WebSocket update (if enabled)</li>
  </ul>
  <br>
  
  <a name="LEDControllerexamples"></a>
  <b>Examples</b>
  <ul>
    <p>Basic usage:</p>
    <code>
    define livingroom_led LEDController 192.168.1.100:80<br>
    attr livingroom_led websocket 1<br>
    attr livingroom_led interval 15<br>
    <br>
    set livingroom_led on<br>
    set livingroom_led brightness 128<br>
    set livingroom_led solid_color FF0000<br>
    set livingroom_led effect 5<br>
    </code>
    <br>
    <p>Automation example:</p>
    <code>
    # Evening mood lighting<br>
    define evening_mood at *19:00:00 { \<br>
    &nbsp;&nbsp;fhem("set livingroom_led on"); \<br>
    &nbsp;&nbsp;fhem("set livingroom_led brightness 80"); \<br>
    &nbsp;&nbsp;fhem("set livingroom_led solid_color FF8000"); \<br>
    }<br>
    </code>
  </ul>
</ul>

=end html
=cut