/// Errors that can occur during message decoding.
pub const DecodeError = error{
    UnknownMessageCode,
    InvalidArrayLength,
    DecodeFailure,
    MissingField,
    InvalidType,
};

/// Errors that can occur during message encoding.
pub const EncodeError = error{
    EncodeFailure,
    UnsupportedType,
    MapPutFailed,
    ArrayElementSetFailed,
};
