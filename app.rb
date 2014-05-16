require 'sinatra/base'
require 'sinatra/activerecord'
require 'json'
require 'oauth2'
require 'net/http'
require 'twilio-ruby'
require 'rack/csrf'
require 'phone'
require './lib/greeter'
require './lib/unlocker'
require './lib/twilio_watcher'
require './lib/zulip_watcher'

def new_oauth_client
  OAuth2::Client.new(
    ENV['HS_OAUTH_ID'],
    ENV['HS_OAUTH_SECRET'],
    :site => 'https://www.hackerschool.com'
  )
end

def new_twilio_client
  return Twilio::REST::Client.new ENV['TWILIO_SID'], ENV['TWILIO_TOKEN']
end

def set_alert(msg, type)
  if defined? session
    session[:msg] = msg
    session[:type] = type
  end
end

def unlock(already=false)
  if $unlocker.unlock
    set_alert 'Door unlocked!', 'success'
  else
    set_alert 'Door was already unlocked. Please wait before trying again.', 'fail'
  end
end

def parse_phone_number(num)
  begin
    Phoner::Phone.default_country_code = '1'
    Phoner::Phone.parse(num).to_s
  rescue Phoner::PhoneError
    false
  end
end

class User < ActiveRecord::Base
end

class DoorbotApp < Sinatra::Base
  register Sinatra::ActiveRecordExtension

  configure do
    enable :sessions
    set :database, 'sqlite:///development.db'
    use Rack::Csrf, :raise => true
    $unlocker = Unlocker.new
    TwilioWatcher.new($unlocker)
    ZulipWatcher.new($unlocker)
  end

  helpers do
    def csrf_token
      Rack::Csrf.csrf_token(env)
    end

    def csrf_tag
      Rack::Csrf.csrf_tag(env)
    end
  end

  get '/' do
    if session[:msg]
      alert_msg = session[:msg]
      alert_type = session[:type] || 'success'
      session[:msg] = nil
    else
      alert_msg = nil
      alert_type = nil
    end
    if logged_in?
      erb :unlock, locals: {user_number: current_user.phone, alert_msg: alert_msg, alert_type: alert_type}
    else
      erb :lock, locals: {alert_msg: alert_msg, alert_type: alert_type}
    end
  end

  post '/login' do
    client = new_oauth_client
    redirect client.auth_code.authorize_url(:redirect_uri => "#{ENV['HS_OAUTH_CALLBACK']}/oauth_callback")
  end

  post '/update_user' do
    if params[:phone] && logged_in?
      user = current_user
      phone = parse_phone_number(params[:phone])
      if phone
        set_alert 'Phone number updated.', 'success'
        user.phone = phone
        user.save
      else
        set_alert 'Invalid or missing phone number.', 'fail'
      end
    end
    redirect to('/')
  end

  get '/oauth_callback' do
    client = new_oauth_client
    token = client.auth_code.get_token(params[:code], :redirect_uri => "#{ENV['HS_OAUTH_CALLBACK']}/oauth_callback")
    json = JSON.parse(token.get('/api/v1/people/me').body)
    school_id = json['id']
    session[:user] = school_id
    unless User.where(school_id: school_id).exists?
      User.create(school_id: school_id)
    end
    redirect to('/')
  end

  get '/logout' do
    session[:user] = nil
    redirect to('/')
  end

  post '/unlock' do
    halt "Please <a href='/login'>login</a>." unless logged_in?

    unlock
    redirect to('/')
  end

  def logged_in?
    ! session[:user].nil?
  end

  def current_user
    unless session[:user].nil?
      User.where(school_id: session[:user]).first
    end
  end
end
