port ENV.fetch("PORT", 4567).to_i
bind "tcp://127.0.0.1:#{ENV.fetch("PORT", 4567)}"

workers ENV.fetch("WEB_CONCURRENCY", 0).to_i
threads 4, 4

preload_app!

on_worker_boot do
  reconnect_db!
end
