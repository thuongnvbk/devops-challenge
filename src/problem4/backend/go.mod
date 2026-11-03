module example.com/shipit/backend

go 1.27

// Pinned so CI and local builds use the same compiler: the release digest
// is only reproducible for a fixed toolchain.
toolchain go1.27.3
