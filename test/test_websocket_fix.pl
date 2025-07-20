#!/usr/bin/perl
# Test the updated WebSocket parsing function from LEDController

use strict;
use warnings;
use JSON;

# Extract just the WebSocket parsing function for testing
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

print "Testing updated WebSocket parsing function...\n";

# Test data from the original issue
my @issue_test_cases = (
    # Case from logs: �{"Client": 4}��
    "\xFF\xFD{\"Client\": 4}\xFF\xFD\xFF\xFD",
    
    # Case from logs: �{"name":"resetCnt","value":5}�{"name":"wifiErrCnt","value":0}�{"Client": 4}��
    "\xFF\xFD{\"name\":\"resetCnt\",\"value\":5}\xFF\xFD{\"name\":\"wifiErrCnt\",\"value\":0}\xFF\xFD{\"Client\": 4}\xFF\xFD\xFF\xFD",
    
    # WebSocket frame format
    "\x81\x0F{\"Client\": 4}\x00\x00",
    
    # Plain JSON (should still work)
    "{\"test\": \"value\"}",
    
    # Empty/garbage data
    "\xFF\xFD\xFF\xFD",
    "",
);

my $test_num = 1;
my $passed = 0;
my $total = scalar(@issue_test_cases);

foreach my $test_data (@issue_test_cases) {
    print "\nTest $test_num: ";
    
    my @results = LEDController_ParseWebSocketFrame($test_data);
    
    if ($test_num <= 4) {  # Tests 1-4 should succeed
        if (@results > 0) {
            print "✓ PASS - Found " . scalar(@results) . " JSON object(s)\n";
            foreach my $json (@results) {
                print "  - " . encode_json($json) . "\n";
            }
            $passed++;
        } else {
            print "✗ FAIL - Expected JSON objects but found none\n";
        }
    } else {  # Tests 5-6 should find no JSON
        if (@results == 0) {
            print "✓ PASS - Correctly found no JSON in garbage/empty data\n";
            $passed++;
        } else {
            print "✗ FAIL - Found unexpected JSON objects in garbage data\n";
        }
    }
    
    $test_num++;
}

print "\n" . "=" x 50 . "\n";
print "Test Results: $passed/$total passed\n";

if ($passed == $total) {
    print "✓ All tests passed! WebSocket parsing fix is working correctly.\n";
    exit 0;
} else {
    print "✗ Some tests failed. Please review the implementation.\n";
    exit 1;
}