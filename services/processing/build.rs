fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")?;
    let proto_root   = format!("{}/../../proto", manifest_dir);

    // Single pass — compile both protos together.
    // prost generates cross-references as events::v1::BaseEvent.
    // processing_v1 lives at crate::grpc::processing_v1, so:
    //   super           = crate::grpc
    //   super::super    = crate
    //   super::super::events::v1 = crate::events::v1  ✅
    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .file_descriptor_set_path(
            std::path::PathBuf::from(std::env::var("OUT_DIR")?)
                .join("processing_descriptor.bin"),
        )
        .compile_protos(
            &[
                &format!("{}/events/v1/event.proto",       proto_root),
                &format!("{}/processing/v1/engine.proto",  proto_root),
            ],
            &[&proto_root],
        )?;

    println!("cargo:rerun-if-changed={}/events/v1/event.proto",      proto_root);
    println!("cargo:rerun-if-changed={}/processing/v1/engine.proto", proto_root);

    Ok(())
}
