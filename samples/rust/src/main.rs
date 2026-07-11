fn fib(n: u32) -> u32 {
    match n {
        0 => 0,
        1 => 1,
        _ => fib(n - 1).wrapping_add(fib(n - 2)),
    }
}

fn license_ok(key: &str) -> bool {
    let secret = "HIKARI-RUST-KEY";
    if key.len() != secret.len() {
        return false;
    }
    key.bytes()
        .zip(secret.bytes())
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

fn main() {
    let banner = "Hello Hikari from Rust!";
    println!("{banner}");

    let n = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(8);
    println!("fib({n}) = {}", fib(n));

    let key = std::env::args().nth(2).unwrap_or_default();
    if license_ok(&key) {
        println!("license valid");
    } else {
        println!("license invalid");
    }
}
