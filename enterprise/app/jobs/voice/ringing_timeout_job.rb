class Voice::RingingTimeoutJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Voice::RingingTimeoutService.overdue.find_each do |call|
      Voice::RingingTimeoutService.new(call: call).perform
    rescue StandardError => e
      # One call that cannot be ended does not hold up the others
      ChatwootExceptionTracker.new(e, account: call.account).capture_exception
    end
  end
end
