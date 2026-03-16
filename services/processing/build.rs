fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")?;
    let proto_root   = format!("{}/../../proto", manifest_dir);

    // Single pass — compile both protos together.
    // prost generates cross-references as super::super::ingestion::v1::MarketEvent.
    // processing_v1 lives at crate::grpc::processing_v1, so:
    //   super           = crate::grpc
    //   super::super    = crate
    //   super::super::ingestion::v1 = crate::ingestion::v1  ✅
    // No extern_path needed.
    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .file_descriptor_set_path(
            std::path::PathBuf::from(std::env::var("OUT_DIR")?)
                .join("processing_descriptor.bin"),
        )
        .compile_protos(
            &[
                &format!("{}/ingestion/v1/events.proto",   proto_root),
                &format!("{}/processing/v1/engine.proto",  proto_root),
            ],
            &[&proto_root],
        )?;

    println!("cargo:rerun-if-changed={}/ingestion/v1/events.proto",  proto_root);
    println!("cargo:rerun-if-changed={}/processing/v1/engine.proto", proto_root);
    Ok(())
}
