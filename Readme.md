# Expression Reference

## Comparison Operators

| Expression | Description              | Examples                                                  |
| ---------- | ------------------------ | --------------------------------------------------------- |
| `==`       | Equals                   | `severity == 'high'` `temperature == 0` `enabled == true` |
| `!=`       | Not equals               | `mode != 'off'` `count != 0` `device_id != null`          |
| `<`        | Less than                | `temperature < 0` `battery_level < 20` `hour < 9`         |
| `>`        | Greater than             | `humidity > 80` `count > 5` `brightness > 50`             |
| `<=`       | Less than or equal to    | `temperature <= 10` `priority <= 3` `volume <= 50`        |
| `>=`       | Greater than or equal to | `battery >= 80` `confidence >= 0.95` `age >= 18`          |

## Logical Operators

| Expression | Description                                                     | Examples                                                                                                                  |
| ---------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `and`      | Logical AND (both conditions must be true)                      | `temperature > 30 and humidity > 70` `enabled == true and mode != 'off'` `count > 0 and count <= 10`                      |
| `or`       | Logical or (at least one condition must be true)                | `severity == 'high' or severity == 'critical'` `temperature < 0 or temperature > 35` `mode == 'auto' or mode == 'manual'` |
| `not`      | Logical not (negates a boolean expression)                      | `not (temperature > 30)` `not enabled` `not (isEmpty(weather_events)`                                                     |
| `( )`      | Parentheses (groups expressions to control order of operations) | `(temperature < 0 or temperature > 35) and enabled` `not (mode == 'off' or mode == 'standby')`                            |

## Arithmetic Operators

| Expression | Description                       | Examples                                          |
| ---------- | --------------------------------- | ------------------------------------------------- |
| `%`        | Modulo (remainder after division) | `hour % 2 == 0` `day % 7 == 0` `counter % 5 == 0` |

## Existence/Empty Checks

| Expression  | Description                                                        | Examples                                     |
| ----------- | ------------------------------------------------------------------ | -------------------------------------------- |
| `isEmpty()` | Returns true if string is empty ("") or array has no elements ([]) | `isEmpty(email)` `isEmpty(selected_devices)` |

## Array Operations

| Expression      | Description                                                          | Examples                                                                                                     |
| --------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `includes()`    | Returns true if array contains the specified value                   | `includes(weather_events, 'rainy')` `includes(['kitchen', 'bedroom'], selected_room)`                        |
| `includesAny()` | Returns true if array contains ANY of the specified values           | `includesAny(weather_events, ['rainy', 'snowy'])` `includesAny(severity, ['high', 'critical', 'emergency'])` |
| `includesAll()` | Returns true if array contains ALL of the specified values           | `includesAll(weather_events, ['rainy', 'windy'])` `includesAll(['heating', 'cooling'], modes)`               |
| `length()`      | Returns the number of elements in an array or characters in a string | `length(weather_events) > 0` `length(notification_text) < 100`                                               |

## String Operations

| Expression     | Description                                             | Examples                                                                       |
| -------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `contains()`   | Returns true if string contains the specified substring | `contains(device_name, 'motion')`                                              |
| `startsWith()` | Returns true if string starts with the specified prefix | `startsWith(entity_id, 'sensor.')` `startsWith(notification_title, '[Alert]')` |
| `endsWith()`   | Returns true if string ends with the specified suffix   | `endsWith(entity_id, '_temperature')`                                          |
