require 'exceptional'

module ExceptionReporting
  module Exceptional
    def report_exception(exception, request = nil)
      begin
        if exception.is_a? String
          # turn string into an exception (with stack trace etc.)
          begin
            raise exception
          rescue RuntimeError => raised_exception
            exception = raised_exception
          end
        end

        if Kernel.environment == 'test'
          puts "Reporting Exception: #{exception}"
          puts "\t" + exception.backtrace.join("\n\t")
        end

        if request
          Exceptional::Catcher.handle_with_rack(exception, request.env, request)
        else
          Exceptional::Catcher.handle(exception)
        end
      rescue Exception => exceptional_error
        DB.logger.error "#{exceptional_error.class}: #{exceptional_error.message}"
        DB.logger.error "\t" + exceptional_error.backtrace.join("\n\t")
      end
    end
  end
end
