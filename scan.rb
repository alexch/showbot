require './whee_mail'

ENV['INCOMING_EMAIL_USER'] = 'showbotapp'
ENV['INCOMING_EMAIL_SECRET'] = 'showbotbot'

r = WheeMail::Receiver.new
r.scan
