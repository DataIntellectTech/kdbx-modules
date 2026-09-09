/ hard module dependencies, di.depcheck-enforced - di.pubsub must be >= 0.2.0 (its .z.pc chaining
/ fix; see subscriptions.md Dependencies for why). log/handlers stay injected, not hard deps
deps:`di.servers`di.pubsub!("0.1.0";"0.2.0");
