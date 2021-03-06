require 'rack'
require 'sidekiq/hierarchy/http'

module Sidekiq
  module Hierarchy
    module Rack
      class Middleware
        # transform from http header to rack names
        JOB_HEADER_KEY = "HTTP_#{Sidekiq::Hierarchy::Http::JOB_HEADER.upcase.gsub('-','_')}".freeze
        WORKFLOW_HEADER_KEY = "HTTP_#{Sidekiq::Hierarchy::Http::WORKFLOW_HEADER.upcase.gsub('-','_')}".freeze

        def initialize(app)
          @app = app
        end

        def call(env)
          if env[WORKFLOW_HEADER_KEY] && env[JOB_HEADER_KEY]
            Sidekiq::Hierarchy.current_job = Job.find(env[JOB_HEADER_KEY])
            Sidekiq::Hierarchy.current_workflow = Workflow.find_by_jid(env[WORKFLOW_HEADER_KEY])
          end
          @app.call(env)
        ensure
          Sidekiq::Hierarchy.current_workflow = nil
          Sidekiq::Hierarchy.current_job = nil
        end
      end
    end
  end
end
