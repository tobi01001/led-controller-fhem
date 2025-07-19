# FHEM LED Controller Module

This module provides FHEM integration for the [LED_Stripe_Dynamic_web_conf](https://github.com/tobi01001/LED_Stripe_Dynamic_web_conf) LED stripe controllers.

## Features

- HTTP GET command support for controlling LED stripes
- Automatic status polling
- WebSocket support for real-time updates (basic implementation)
- Full FHEM integration with readings and attributes
- Error handling and logging

## Installation

1. Copy `FHEM/98_LEDController.pm` to your FHEM modules directory (usually `/opt/fhem/FHEM/`)
2. Restart FHEM or reload the module: `reload 98_LEDController`

## Usage

### Define a device

```
define myLED LEDController 192.168.1.100:80
```

### Control the LED stripe

```bash
# Turn on/off
set myLED on
set myLED off

# Set brightness (0-255)
set myLED brightness 128

# Set color (hex format)
set myLED color FF0000  # Red
set myLED color 00FF00  # Green
set myLED color 0000FF  # Blue

# Set effects
set myLED effect rainbow
set myLED effect fade
set myLED effect strobe

# Set effect speed (1-100)
set myLED speed 50

# Reset to defaults
set myLED reset
```

### Get information

```bash
# Get current status
get myLED status

# Get configuration
get myLED config

# Get firmware version
get myLED version
```

### Attributes

- `interval` - Status update interval in seconds (default: 30)
- `timeout` - HTTP timeout in seconds (default: 5)  
- `disable` - Disable device (0/1, default: 0)
- `websocket` - Enable WebSocket connection (0/1, default: 0)

### Example FHEM configuration

```perl
# Define the LED controller
define livingroom_led LEDController 192.168.1.100:80

# Set some attributes
attr livingroom_led interval 60
attr livingroom_led timeout 10

# Create some aliases for easier control
define led_on DOIF ([$SELF:""])(set livingroom_led on)
define led_off DOIF ([$SELF:""])(set livingroom_led off)
```

## API Endpoints

The module expects the LED controller to respond to these HTTP GET endpoints:

- `/on` - Turn LED strip on
- `/off` - Turn LED strip off
- `/brightness/<value>` - Set brightness (0-255)
- `/color/<RRGGBB>` - Set color in hex format
- `/effect/<name>` - Set effect
- `/speed/<value>` - Set effect speed (1-100)
- `/status` - Get current status (JSON response expected)
- `/config` - Get configuration (JSON response expected)
- `/version` - Get firmware version (JSON response expected)
- `/reset` - Reset to default settings

## JSON Response Format

The module expects JSON responses for status, config, and version endpoints:

```json
{
  "state": "on",
  "brightness": 255,
  "color": "FF0000",
  "effect": "solid",
  "speed": 50
}
```

## WebSocket Support

Basic WebSocket support is included but requires further implementation. When enabled with `attr <device> websocket 1`, the module will attempt to connect to the WebSocket endpoint for real-time updates.

## Troubleshooting

1. Check FHEM logs for error messages
2. Verify network connectivity to the LED controller
3. Test HTTP endpoints manually using curl or browser
4. Ensure JSON responses are properly formatted

## Contributing

This module is part of the led-controller-fhem project. Please submit issues and pull requests to the GitHub repository.
