pub const SigError = error{
    CapacityExceeded,
    BufferTooSmall,
    DepthExceeded,
    QuotaExceeded,
};
