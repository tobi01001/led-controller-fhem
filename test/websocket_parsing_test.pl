#!/usr/bin/perl
# Test script for WebSocket frame parsing issue reproduction
# Tests the fix for garbage characters in WebSocket data

use strict;
use warnings;
use JSON;

# Mock FHEM functions for testing
sub Log3 { 
    my ($name, $level, $msg) = @_; 
    print "[LOG$level] $name: $msg\n"; 
    return $msg; # Return for test validation
}

sub readingsBeginUpdate { print "Readings begin\n"; }
sub readingsBulkUpdate { print "Reading bulk update\n"; }
sub readingsEndUpdate { print "Readings end\n"; }

print "Testing WebSocket frame parsing...\n";

# Test data examples from the issue
my @test_frames = (
    # Single JSON with frame headers
    "\x81\x0F{\"Client\": 4}\x00\x00",
    
    # Multiple JSON objects in one frame 
    "\x81\x45{\"name\":\"resetCnt\",\"value\":5}\x00{\"name\":\"wifiErrCnt\",\"value\":0}\x00{\"Client\": 4}\x00\x00",
    
    # Text frame with garbage
    "\x81\x0F\xFF\xFD{\"Client\": 4}\xFF\xFD\x1F",
    
    # Plain JSON (should work)
    "{\"name\":\"test\",\"value\":123}",
);

print "\n=== Current (broken) parsing method ===\n";
foreach my $i (0..$#test_frames) {
    my $data = $test_frames[$i];
    print "Test " . ($i+1) . ": ";
    
    # Current parsing logic (broken)
    if($data =~ /\{.*\}/) {
        if($data =~ /(\{.*\})/) {
            my $json_data = $1;
            eval {
                my $json = decode_json($json_data);
                print "✓ Parsed JSON successfully\n";
            };
            if($@) {
                print "✗ JSON parse error: $@";
            }
        }
    } else {
        print "✗ No JSON pattern found\n";
    }
}

print "\n=== Improved parsing method ===\n";

sub parse_websocket_frame {
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
            
            # Extract payload
            if (length($data) >= $payload_start + $payload_length) {
                $data = substr($data, $payload_start, $payload_length);
            }
        }
    }
    
    # Clean up any remaining control characters
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
        
        if ($brace_count == 0) {
            my $json_str = substr($data, $start, $end - $start + 1);
            eval {
                my $json = decode_json($json_str);
                push @json_objects, $json;
            };
            if ($@) {
                Log3("test", 3, "JSON parse error for: $json_str - $@");
            }
        }
        
        $pos = $end + 1;
    }
    
    return @json_objects;
}

foreach my $i (0..$#test_frames) {
    my $data = $test_frames[$i];
    print "Test " . ($i+1) . ": ";
    
    my @json_objects = parse_websocket_frame($data);
    if (@json_objects) {
        print "✓ Parsed " . scalar(@json_objects) . " JSON object(s) successfully\n";
        foreach my $json (@json_objects) {
            print "  - " . encode_json($json) . "\n";
        }
    } else {
        print "✗ No valid JSON objects found\n";
    }
}

print "\nWebSocket parsing test complete!\n";