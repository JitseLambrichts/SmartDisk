use slim_core::{config::Config, db::Db, embed::default_embedder, index::Indexer};
use std::{fs, path::PathBuf, process::Command};

fn cli(root: &std::path::Path, args: &[&str]) -> serde_json::Value {
    let out = Command::new(env!("CARGO_BIN_EXE_slim")).args(args).arg("--json").env("SLIM_HOME", root).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn sensitive_documents_stay_out_of_search_and_removing_a_source_revokes_access() {
    let root = std::env::temp_dir().join(format!("smartdisk-scope-{}", std::process::id()));
    let source = root.join("source");
    fs::create_dir_all(&source).unwrap();
    fs::write(source.join("passport.txt"), "Passport. Nationality: British. Date of birth: 01/01/2000.").unwrap();
    fs::write(source.join("note.txt"), "ordinary document").unwrap();
    cli(&root, &["folders", "add", source.to_str().unwrap()]);
    cli(&root, &["index"]);
    assert!(cli(&root, &["query", "passport"])["items"].as_array().unwrap().is_empty());
    assert!(cli(&root, &["grep", "passport"]).as_array().unwrap().is_empty());
    cli(&root, &["settings", "set", "sensitive", "true"]);
    assert_eq!(cli(&root, &["query", "passport"])["items"].as_array().unwrap().len(), 1);
    cli(&root, &["folders", "remove", source.to_str().unwrap()]);
    assert!(cli(&root, &["query", "passport"])["items"].as_array().unwrap().is_empty());
    assert!(cli(&root, &["grep", "ordinary"]).as_array().unwrap().is_empty());
    let db = Db::open(&root.join("index.sqlite")).unwrap();
    assert_eq!(db.count_files().unwrap().0, 0);
    drop(db);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn turning_off_document_text_clears_existing_search_text() {
    let root = std::env::temp_dir().join(format!("smartdisk-privacy-{}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let file = root.join("note.txt");
    fs::write(&file, "A private document with a phrase that must be removed.").unwrap();
    let config = Config { folders: vec![root.clone()], ..Config::default() };
    fs::write(root.join("config.json"), serde_json::to_vec(&config).unwrap()).unwrap();
    let path: PathBuf = root.join("index.sqlite");
    {
        let mut db = Db::open(&path).unwrap();
        let embedder = default_embedder();
        Indexer::new(&mut db, &config, embedder.as_ref()).index_path(&file).unwrap();
        let count: i64 = db.conn.query_row("SELECT COUNT(*) FROM chunks WHERE text IS NOT NULL", [], |r| r.get(0)).unwrap();
        assert!(count > 0);
    }
    let output = Command::new(env!("CARGO_BIN_EXE_slim"))
        .args(["settings", "set", "full-text", "false", "--json"])
        .env("SLIM_HOME", &root).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let db = Db::open(&path).unwrap();
    let remaining: i64 = db.conn.query_row("SELECT COUNT(*) FROM chunks WHERE text IS NOT NULL", [], |r| r.get(0)).unwrap();
    assert_eq!(remaining, 0, "Privacy setting must apply to already indexed files");
    drop(db);
    fs::remove_dir_all(root).unwrap();
}
