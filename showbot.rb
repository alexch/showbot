require 'rubygems'
require 'bundler'
require 'sinatra'
require 'erector'
require 'erector/widgets/page'
require 'pp'
require 'json'
require 'oauth'
require 'oauth/consumer'

class Rack::Request
  def site
    url = scheme + "://"
    url << host

    if scheme == "https" && port != 443 ||
        scheme == "http" && port != 80
      url << ":#{port}"
    end

    url
  end
end

BURLESQUE_PROJECT_ID = 1
SHOWBOT_USER_ID = 2

def credentials
  @credentials ||= if ENV['COHUMAN_API_KEY']
    {:key => ENV['COHUMAN_API_KEY'], :secret => ENV['COHUMAN_API_SECRET']}
  else
    begin
      here = File.expand_path(File.dirname(__FILE__))
      YAML.load( File.read( "#{here}/config/cohuman.yml") )
    rescue Errno::ENOENT
      nil
    end
  end
end

def consumer
  @consumer ||= OAuth::Consumer.new( credentials[:key], credentials[:secret], {
    :site => 'http://api.sandbox.cohuman.com',
    :request_token_path => '/api/token/request',
    :authorize_path => '/api/authorize',
    :access_token_path => '/api/token/access'
    })
end

def api_url(path)
  path.gsub!(/^\//,'') # removes leading slash from path
  url = "http://api.sandbox.cohuman.com/#{path}"
end

def access_token
  OAuth::AccessToken.from_hash(consumer, :oauth_token => credentials[:oauth_token], :oauth_token_secret => credentials[:oauth_token_secret])
end

def api_get(url, params = {})
  api_call(:get, url, params)
end

def api_post(url, params = {})
  api_call(:post, url, params)
end

def api_call(method, url, params)
  params = {"format" => "json"}.merge(params)
  response = access_token.send(method, url, params)
  result = begin
    JSON.parse(response.body)
  rescue
    {
      :response => "#{response.code} #{response.message}",
      :headers => response.to_hash,
      :body => response.body
    }
  end
  result
end

enable :sessions

get "/" do
  erb :start
end

get "/show" do
  erb :showtime
end

get "/dashboard" do
  @shows = shows['projects']['favorites'].map { |show| show_details show }
  erb :dashboard
end

post "/fan" do
  access_token.post(api_url("/project/#{BURLESQUE_PROJECT_ID}/member"), :addresses => params[:email], :format => :json)
  "ok"
end

def shows
  response = access_token.get api_url("/projects")
  JSON.parse(response.body)
end

def show_details show
  response = access_token.get api_url(show['path'])
  JSON.parse(response.body)['project']
end

post "/in" do
  do_in(params)
end

get "/in" do
  do_in(params)
end

def do_in(params)
  first_line = params[:plain].split("\n").first.strip
  first_line =~ /([a-zA-Z]+)(\d+)/
  prefix, suffix = $1, $2
  promo_code = "#{prefix}#{suffix}"
  
  result = api_get(api_url("/project/#{BURLESQUE_PROJECT_ID}"))
  project = result['project']
  tasks = project['tasks']
  task = tasks.detect do |task|
    name = task['name']
    (name.split.last == promo_code)
  end
  
  if task.nil?
    halt 404
  else
    task_id = task['id'].to_i
    # add companion as a follower
    result = api_post("/task/#{task_id}/follower", :addresses => params[:from])  # todo: be smart about from vs. sender, using RFC822 headers
    # todo: error handling
    pp result
    
    # add "you win" comment
    result = api_post("/task/#{task_id}/comment", :text => "ZOMG you both get to go to #{project['name']} for free!")
    # todo: error handling
    pp result

    # finish it
    result = api_post("/task/#{task_id}/activity/finish")
    # todo: error handling
    pp result
    
    "ok"
  end
end

post "/show/:show_id/promo/:prefix" do
  do_promo(params)
end


post "/show/:show_id/promo" do
  do_promo(params)
  erb :dashboard
end

def do_promo(params)
  # for each member
  #   make a task with a different promo code "boobs123"
  #   add member as a follower
  #   add comment: "email this code blah blah"
  project = api_get(api_url("/project/#{params[:show_id]}"))
  members = project['project']['members']
  out = []
  members.each do |member|
    member_id = member['id'].to_i
    next if member_id == SHOWBOT_USER_ID
    this_out = {'member_id' => member_id}
    
    promo_suffix = rand(10000)  # todo: make it really unique
    promo_code = "#{params[:prefix]}#{promo_suffix}"
    this_out['promo_code'] = promo_code
        
    result = api_post(api_url("/task"), 
      :name => "Invite a friend to #{project['project']['name']} with #{promo_code}",
      :project_id => params[:show_id], 
      :owner_id => member_id)
    task_id = result['task']['id'].to_i
    this_out['task_id'] = task_id
    
    result = api_post(api_url("/task/#{task_id}/comment"), :text => 
      "Invite a friend to join you at #{project['project']['name']}! Have your friend send an email to showbotapp@gmail.com with #{promo_code} as the first line of the email.")
    comment_id = result['comment']['id'].to_i
    this_out['comment_id'] = comment_id
    
    out << this_out
  end
  spew out
end

def spew x
  "<pre>#{x.pretty_inspect}</pre>"
end

######
get "/authorize" do
  if credentials
    request_token = consumer.get_request_token(:oauth_callback=>"#{request.site}/authorized")
    session[:request_token] = request_token
    redirect request_token.authorize_url
  else
    erector {
      h1 "Configuration error"
      ul {
        li {
          text "Please set the environment variables "
          code "COHUMAN_API_KEY"
          text " and " 
          code "COHUMAN_API_SECRET"
        }
        li {
          text " or create "
          code "config/cohuman.yml"
        }
      }
      p "For a Heroku app, do it like this:"
      pre <<-PRE
heroku config:add COHUMAN_API_KEY=asldjasldkjal
heroku config:add COHUMAN_API_SECRET=asdfasdfasdf
      PRE
    }
  end
end
    
get "/authorized" do
  request_token = session[:request_token]
  access_token = request_token.get_access_token
  session.delete :request_token  # comment this line out if you want to see the request token in the session table
  puts access_token.inspect
  session[:access_token] = access_token
  redirect "/"
end

get "/logout" do
  if session[:access_token].nil?
    redirect "/"
    return
  end
  
  url = api_url("/logout")
  response = session[:access_token].post(url, {"Content-Type" => "application/json"})
  result = begin
    JSON.parse(response.body)
  rescue
    {
      :response => "#{response.code} #{response.message}",
      :headers => response.to_hash,
      :body => response.body
    }
  end
  
  session.delete(:access_token)
  session.delete(:request_token)

  render_page(url, result)
end
