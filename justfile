# Check contract sizes for vault contracts using release profile
check-sizes:
    FOUNDRY_PROFILE=release forge build --sizes src/vaults
