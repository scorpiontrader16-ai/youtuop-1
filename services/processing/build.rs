fn main() -> Result<(), Box<dyn std::error::Error>> {
    // CARGO_MANIFEST_DIR is set by cargo to the directory containing Cargo.toml
    // This makes the path work both locally and in CI regardless of working directory
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")?;
    let proto_root = format!("{}/../../proto", manifest_dir);
    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .file_descriptor_set_path(
            std::path::PathBuf::from(std::env::var("OUT_DIR")?)
                .join("processing_descriptor.bin"),
        )
        .compile_protos(
            &[
                &format!("{}/processing/v1/engine.proto", proto_root),
                &format!("{}/ingestion/v1/events.proto", proto_root),
            ],
            &[&proto_root],
        )?;
    // Re-run build script if any proto file changes
    println!("cargo:rerun-if-changed={}/processing/v1/engine.proto", proto_root);
    println!("cargo:rerun-if-changed={}/ingestion/v1/events.proto", proto_root);
    Ok(())
}
