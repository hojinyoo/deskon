# Domain -- linak-control
<!-- Business rules, data models, entities, domain language. Updated: 2026-04-02 -->

## LINAK DPG1C Protocol

- **Height values**: uint16 in 0.1mm units (LE). Raw = relative to desk's lowest position.
- **Display height**: raw + user-configured desk offset (stored in config as `desk_offset_mm`)
- **Preset heights**: stored in DPG as raw values. Response format: [status, length, slot, height_lo, height_hi, ...]
- **Height range**: 0-~650mm travel (raw). DeskLimits.validHeightRange = 0...7000, safeCommandRange = 0...6500
- **Speed threshold**: abs(speed) < 5 treated as stationary (deceleration filtering)

## DPG Session Activation

1. Enable notifications on status (0x0003), DPG (0x0011), height (0x0021)
2. Read output mask (0x0029) -- must be 0x01
3. Read USER_ID (0x7F 0x81 0x00) -- if byte 0 of payload != 0x01, write back with correction
4. Issue DPG queries: capabilities, capabilities_ext, desk_offset, presets 1-4

Without step 3, desk returns 0x0B error to all queries.

## DPG Response Format

All DPG responses: [status_byte, length_byte, ...payload]
- status 0x01 = success, 0x0B = error
- Read commands: [0x7F, cmd, 0x00] (3rd byte = read mode)
- Write commands: [0x7F, cmd, 0x80, ...data] (3rd byte = write mode)

## Movement

- Manual: repeat moveUp [0x47 0x00] or moveDown [0x46 0x00] to command char every 100ms
- Auto/Preset: preflight [0x00 0x00] to command, then moveTo target to 0x0031 every 100ms
- Stop: [0xFF 0x00] to command (send twice)
- Wake: [0xFE 0x00] to command before movement if idle
- Idle: no writes at all. A keep-alive on 0x0031 locks out the desk's own panel (see troubleshooting)
