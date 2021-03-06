class TestWorker
  include Sidekiq::Worker
  sidekiq_options workflow: true
  def perform(child_worker=nil, child_args=[])
    child_klass.constantize.perform_async(*child_args) if child_args.any?
  end
end
