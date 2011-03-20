require 'rubygems'
require 'mail'
require 'openssl'
require 'tlsmail'
require 'net/imap'
require './exception_reporting'

class Hash
  # alias shovel to merge
  alias :<< :merge
  
  # turns a hash into a hash
  def remap
    # This is Ruby magic for turning a hash into an array into a hash again
    Hash[*self.map do |key, value|
      yield key, value
    end.compact.flatten]
  end
  
end

# WheeMail - minimal emailer
#
# Author: Alex Chaffee <alex@cohuman.com>
#
module WheeMail

  def self.environment
    ENV['RACK_ENV'] || "development"
  end
  
  def self.environment_variable(name)
    ENV[name] || (warn "missing environment variable #{name}")
  end

  class Config

    def self.get(env = WheeMail.environment)

      gmail_imap = {
        :server => "imap.gmail.com",
        :port => 993,
        :authtype => :plain
        
      }

      sendgrid = {
        :server   => "smtp.sendgrid.net",
        :port     => 587,
        :authtype => :plain
      }

      Config.new case env
      when "production", "development"
        {
          :from => 'showbotapp@gmail.com',
          :outgoing => sendgrid << {
            # :user => WheeMail.environment_variable('OUTGOING_EMAIL_USER'),
            # :secret => WheeMail.environment_variable('OUTGOING_EMAIL_SECRET'),
            # :helo => WheeMail.environment_variable('OUTGOING_EMAIL_HELO')
          },
          :incoming => gmail_imap << {
            :user => WheeMail.environment_variable('INCOMING_EMAIL_USER'),
            :secret => WheeMail.environment_variable('INCOMING_EMAIL_SECRET')
          }
        }

      when "test"
          {
            :from => 'app@example.com',
            :new_task_address => 'new@example.com',
            :outgoing => {
              :server => "smtp.example.com",
              :port => 587,
              :authtype => :plain,            
              :user => "testuser",
              :secret => "password",
              :helo => "example.com",
              },
              :incoming => {
                :server => "imap.example.com",
                :port => 993,
                :user => "testuser",
                :secret => "password",
              }
            }

      else
          raise "missing email config for environment #{env}"
      end
    end

    def initialize(data)
      @data = data.remap do |k,v|
        if v.is_a?(Hash)
          [k, Config.new(v)]
        else
          [k,v]
        end
      end
    end

    def method_missing(method_name, * args)
      @data[method_name]
    end

    def [](key)
      @data[key]
    end
  end

  class IncomingMessage
    include ExceptionReporting

    attr_reader :mail, :config

    def initialize(rfc822, config = Config.get)
      @config = config
      @mail = Mail.new(rfc822)
      @rfc822 = rfc822
    end

    def subject
      strip_res(mail.subject || "")
    end

    def process_body(body)
      body.gsub!(/\r\n/, "\n") # remove network newlines

      if (mail['X-Mailer'] && (mail['X-Mailer'].to_s =~ /iPhone Mail/))
        parts = body.split(/^Begin forwarded message:$/)
        if parts.size == 2
          body = parts.first + "Begin forwarded message:" + parts.last.gsub(/^> ?/, '')
        end
      end

      body = body.
      gsub(/^--+( *)$.*/m, '').# remove .sig
      gsub(/^__+( *)$.*/m, '') # remove yahoo fwd

      # emails come in iso-8859-1; we like utf-8
      body = Iconv.iconv('utf-8', 'iso-8859-1', body).join('')

      body.strip!

      body = strip_fwd_lines(body)

      return body
    end

    def strip_fwd_lines(body)
      lines = body.split("\n")
      while !lines.empty? && fwd?(lines.last)
        lines.pop
      end

      if (lines.last =~ /^[^ ]*:$/ && lines[lines.size - 2] != /^On /)
        lines.pop
        lines.pop
      end

      lines.join("\n").strip
    end

    def fwd?(line)
      line.blank? || line =~ /^>/ || line.match(/^On .*:$/)
    end

    def find_comment
      if mail.multipart?
        mail.parts.each do |part|
          # http://en.wikipedia.org/wiki/MIME#Content-Disposition
          # http://www.oreillynet.com/mac/blog/2005/12/forcing_thunderbird_to_treat_o.html
          next if part["content-disposition"] =~ "attachment"
          if part["content-type"].to_s =~ %r(^text/plain)
            return part.body.to_s
          elsif part["content-type"].to_s =~ %r(^multipart/alternative)
            return part.text_part.body.decoded
          end
        end
        mail.parts.first.body.to_s # depends on part-sort-order putting text/plain first
      else
        mail.body.to_s
      end
    end

    def recipients
      ([mail.to] + [mail.cc] + [mail["Delivered-To"].to_s]).flatten.compact
    end

    def process
      puts self.find_comment
    end

    protected
    def strip_res(subject)
      subject.gsub(/^((re:|fwd:) *)*/i, '').strip
    end

    def process_message_ids(* args)
      args.join(", ").split(/, ?/).map do |s|
        s.strip.gsub(/^</, '').gsub(/>$/, '')
      end.reject do |s|
        s.blank?
      end.compact.uniq
    end
  end

  # receives email messages
  class Receiver
    include ExceptionReporting

    attr_reader :config, :keep, :debug

    def initialize(opts = {})
      @config = !!opts[:config]
      @keep = opts[:keep].nil? ? true : !!opts[:keep]
      @debug = !!opts[:debug]
    end

    def config
      @config || Config.get
    end

    # todo: make a new mixin or Kernel method
    def logger
      DB.logger
    end

    def receive(rfc822)
      puts "--- received email:\n#{rfc822}" if @debug
      received_message = IncomingMessage.new(rfc822, config)
      received_message.process
      received_message
    end

    def log_exception(e)
      report_exception(e) if respond_to?(:report_exception)
      say e.to_s
    end

    # todo: figure out how to test
    def scan
      incoming_config = config.incoming
      if incoming_config.nil?
        logger.error("Not scanning for incoming mail, since environment is '#{WheeMail.environment}'")
        return
      end

      say "Starting scan at #{Time.now}"
      c,e,n = nil,nil

      begin
        imap = Net::IMAP.new(incoming_config.server, incoming_config.port, true, nil, false)
        imap.login(incoming_config.user, incoming_config.secret)
        say "IMAP login complete"
        imap.select('INBOX')
        messages = imap.search(["NOT", "DELETED"])
        n = messages.size
        c = e = 0
        messages.each do |message_id|
          rfc822 = imap.fetch(message_id, "RFC822")[0].attr["RFC822"]
          begin
            received_message = receive(rfc822)
            say "Processed message #{received_message.mail.subject}"
            c += 1
          rescue Exception => exception
            # todo: move message into an "error" folder so it doesn't get reprocessed, but don't delete it
            log_exception(exception)
            say "Error processing message #{message_id}"
            e += 1
          ensure
            if !keep
              say "Deleting message #{message_id}"
              imap.store(message_id, "+FLAGS", [:Deleted])
            end
          end
        end

        imap.close # Sends a CLOSE command to close the currently selected mailbox. The CLOSE command permanently removes from the mailbox all messages that have the \Deleted flag set.
        imap.logout
        imap.disconnect
        # NoResponseError and ByeResponseError happen often when imap'ing
      rescue Net::IMAP::NoResponseError => e
        log_exception(e)
      rescue Net::IMAP::ByeResponseError => e
        # ignore
      rescue Exception => e
        log_exception(e)
      end
      say "Processed #{c.inspect} of #{n.inspect} emails received (#{e} errors)."
    end

    # run as a DelayedJob
    # to start this off, do "Receiver.new.perform" from "heroku console"
    def perform
      scan
      job = Delayed::Job.enqueue self, 0,Time.now.utc + 20.seconds  # requeue for next time; 20 second wait to give us a chance to kill the job if need be
      #    say "Receiver enqueued job #{job.id}"
    end

    def say message
      puts "#{Time.now} - #{message}" # was: logger.info(message) but that wasn't working
    end

  end

end
