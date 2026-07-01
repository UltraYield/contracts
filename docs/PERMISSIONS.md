# Roles, Permissions, and Operations

## Role model in vault contracts

The vault uses `AccessControl` roles:

- `DEFAULT_ADMIN_ROLE` (owner-equivalent governance role)
- `OPERATOR_ROLE` (redeem fulfillment operator)
- `PAUSER_ROLE` (pause/unpause operations)
- `UPGRADER_ROLE` (upgrade proposal/authorization)

Owner-only checks in code generally map to `DEFAULT_ADMIN_ROLE`.

## Role identifiers

- `DEFAULT_ADMIN_ROLE`: 0x00
- `OPERATOR_ROLE`: 0x97667070c54ef182b0f5858b034beac1b6f3089aa2d3188bb1e8929f4fa9b929
- `PAUSER_ROLE`: 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a
- `UPGRADER_ROLE`: 0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3

## User-level delegated access

Controllers can assign operators via `setOperator(operator, approved)`.

An authorized operator can act for that controller in request/cancel/claim flows where `checkAccess(controller)` is enforced.

## Permission boundaries

- **Operator**
  - can fulfill pending redeems (single/batch)
  - cannot change fee config or critical addresses unless separately privileged
- **Pauser**
  - can pause/unpause vault operations
- **Admin/Owner**
  - fee updates and fee recipient updates
  - propose/accept rate provider updates
  - propose/accept oracle updates
  - propose/accept funds holder updates
- **Upgrader**
  - can execute upgrade-timelock-governed upgrade actions

## Operational runbook

### Normal operation

1. Keep vault unpaused for deposits/mints.
2. Monitor pending redeem queue and fulfill on schedule.
3. Update prices and conversion sources under established process.
4. Periodically collect fees or rely on automatic collection triggers.

### Critical change procedure

1. Propose new critical address.
2. Wait timelock period.
3. Accept change before expiry window.
4. Verify operational readiness.
5. Unpause vault.

### Incident response

1. Pause vault to stop new deposits/mints.
2. Diagnose oracle/rate/custody issue.
3. Reconfigure and validate.
4. Resume by unpausing when safe.
