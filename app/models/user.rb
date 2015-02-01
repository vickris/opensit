require 'textacular/searchable'

class User < ActiveRecord::Base
  attr_accessible :city, :country, :website, :default_sit_length, :dob,
                  :password, :email, :first_name, :gender, :last_name,
                  :practice, :style, :user_type, :username,
                  :who, :why, :password_confirmation, :remember_me, :avatar,
                  :privacy_setting, :receive_email, :selected_users

  has_many :sits, :dependent => :destroy
  has_many :messages_received, -> { where receiver_deleted: false }, class_name: 'Message', foreign_key: 'to_user_id'
  has_many :messages_sent, -> { where sender_deleted: false }, class_name: 'Message', foreign_key: 'from_user_id'
  has_many :comments, :dependent => :destroy
  has_many :relationships, foreign_key: "follower_id", dependent: :destroy
  has_many :followed_users, through: :relationships, source: :followed
  has_many :reverse_relationships, foreign_key: "followed_id",
                                   class_name:  "Relationship",
                                   dependent:   :destroy
  has_many :followers, through: :reverse_relationships, source: :follower
  has_many :likes, dependent: :destroy
  has_many :notifications, :dependent => :destroy
  has_many :favourites, dependent: :destroy
  has_many :favourite_sits, through: :favourites,
                            source: :favourable,
                            source_type: "Sit"
  has_many :goals, :dependent => :destroy
  has_many :reports, :dependent => :destroy
  has_many :authorised_users, :dependent => :destroy

  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable

  # Devise :validatable (above) covers validation of email and password
  validates :username, length: { minimum: 3, maximum: 20 }
  validates_uniqueness_of :username
  validates :username, no_empty_spaces: true

  # Textacular: search these columns only
  extend Searchable(:username, :first_name, :last_name, :city, :country)

  # Pagination: sits per page
  self.per_page = 10

  # Paperclip
  has_attached_file :avatar, styles: {
    small_thumb: '50x50#',
    thumb: '250x250#',
  }
  validates_attachment :avatar, content_type: { content_type: ["image/jpg", "image/jpeg", "image/png", "image/gif"] }

  # Scopes
  scope :newest_first, -> { order("created_at DESC") }

  # Privacy
  scope :privacy_selected_users, ->(user) { select('users.id')
      .joins('LEFT JOIN authorised_users ON authorised_users.user_id = users.id')
      .where('(authorised_users.authorised_user_id = ? AND users.id IN (?))', user.id, user.followed_user_ids) }
  scope :privacy_following_users, ->(user) { select('users.id')
      .where("users.id IN (?) AND users.privacy_setting = 'following'", user.mutual_following_ids) }

  # Used by url_helper to determine user path, eg; /buddha and /user/buddha
  def to_param
    username
  end

  def city?
    !city.blank?
  end

  def country?
    !country.blank?
  end

  ##
  # VIRTUAL ATTRIBUTES
  ##

  # Location based on whether/if city and country have been entered
  def location
    return "#{city}, #{country}" if city? && country?
    return city if city?
    return country if country?
  end

  def display_name
    return username if first_name.blank?
    return first_name if last_name.blank?
    "#{first_name} #{last_name}"
  end

  ##
  # METHODS
  ##

  def latest_sit(current_user)
    if self == current_user
      Sit.unscoped do
        return sits.newest_first.limit(1)
      end
    else
      return sits.newest_first.limit(1)
    end
  end

  def sits_by_year(year)
    sits.where("EXTRACT(year FROM created_at) = ?", year.to_s)
  end

  def sits_by_month(month, year, current_user = nil)
    if current_user = self
      sits.where("EXTRACT(year FROM created_at) = ?
        AND EXTRACT(month FROM created_at) = ?", year.to_s, month.to_s.rjust(2, '0'))
    elsif current_user
      sits.where("EXTRACT(year FROM created_at) = ?
        AND EXTRACT(month FROM created_at) = ?", year.to_s, month.to_s.rjust(2, '0'))
      .where('user_id in (?)', current_user.users_whose_content_i_can_view)
    else
      # Guests - public only
      # Make where("sits.user_id IN (?)", public_users) a scope to use in EXPLORE too
    end
  end

  def time_sat_this_month(month: month, year: year)
    minutes = sits.where("EXTRACT(year FROM created_at) = ?
      AND EXTRACT(month FROM created_at) = ?", year.to_s, month.to_s.rjust(2, '0')).sum(:duration)
    total_time = minutes.divmod(60)
    text = "#{total_time[0]} hours"
    text << " #{total_time[1]} minutes" if !total_time[1].zero?
    text
  end

  # Do not put me in a loop! Use #days_sat_in_date_range
  # Returns true if user sat on the date passed
  def sat_on_date?(date)
    sits.where(created_at: date.beginning_of_day..date.end_of_day).present?
  end

  # Convenience method for generating monthly stats for /u/
  def get_monthly_stats(month, year)
    @stats = {}
    @stats[:days_sat_this_month] = days_sat_in_date_range(Date.new(year.to_i, month.to_i, 01), Date.new(year.to_i, month.to_i, -1))
    @stats[:time_sat_this_month] = time_sat_this_month(month: month, year: year)
    @stats[:entries_this_month] = sits_by_month(month, year).count
    @stats
  end

  # Returns the number of days, in a date range, where the user sat
  def days_sat_in_date_range(start_date, end_date)
    all_dates = sits.where(created_at: start_date.beginning_of_day..end_date.end_of_day).order('created_at DESC').pluck(:created_at)
    last_one = total = 0
    # Dates are ordered so just check the current date aint the same day as the one before
    # This stops multiple sits in one day incrementing the total by more than 1
    all_dates.each do |d|
      total += 1 if d.strftime("%d %B %Y") != last_one
      last_one = d.strftime("%d %B %Y")
    end
    total
  end

  # Do not put me in a loop! Use #days_sat_for_min_x_minutes_in_date_range
  def sat_for_x_on_date?(minutes, date)
    if sits.where(created_at: date.beginning_of_day..date.end_of_day).present?
      time_sat_on_date(date) >= minutes
    else
      false
    end
  end

  # Returns the number of days, in a date range, where user sat for a minimum x minutes that day
  def days_sat_for_min_x_minutes_in_date_range(duration, start_date, end_date)
    all_sits = sits.where(created_at: start_date.beginning_of_day..end_date.end_of_day).order('created_at DESC')
    all_datetimes = all_sits.pluck(:created_at)
    all_dates = []
    all_datetimes.each do |d|
      all_dates.push d.strftime("%d %B %Y")
    end
    all_dates.uniq! # Stop multiple sits on the same day incrementing the total

    total_days = 0

    all_dates.each do |d|
      total_time = 0
      all_sits.where(created_at: d.to_date.beginning_of_day..d.to_date.end_of_day).each do |s|
        total_time += s.duration
      end
      total_days += 1 if total_time >= duration
    end
    total_days
  end

  def time_sat_on_date(date)
    total_time = 0
    sits.where(created_at: date.beginning_of_day..date.end_of_day).each do |s|
      total_time += s.duration
    end
    total_time
  end

  def total_hours_sat
    sits.sum(:duration) / 60
  end

  # Returns list of months a user has sat, and sitting totals for each month
  def journal_range
    return false if self.sits.empty?

    first_sit = Sit.where("user_id = ?", self.id).order(:created_at).first.created_at.strftime("%Y %m").split(' ')
    year, month = Time.now.strftime("%Y %m").split(' ')
    dates = []

    # Build list of all months from first sit to current date
    while [year.to_s, month.to_s.rjust(2, '0')] != first_sit
      month = month.to_i
      year = year.to_i
      if month != 0
        dates << [year, month]
        month -= 1
      else
        year -= 1
        month = 12
      end
    end

    # Add first sitting month
    dates << [first_sit[0].to_i, first_sit[1].to_i]

    # Object to return, containing two arrays
    @obj = {}

    # Used to list number of sits per month
    @obj[:sitting_totals] = []

    # Used to provide a simple list of available months for dropdown select navigation
    @obj[:list_of_months] = []

    # Filter out any months with no activity
    pointer = 2000

    # dates is an array of months: ["2014 10", "2014 9"]
    dates.each do |m|
      year, month = m
      month_total = self.sits_by_month(month, year).count

      if pointer != year
        year_total = self.sits_by_year(year).count
        @obj[:sitting_totals] << [year, year_total] if !year_total.zero?
      end

      if month_total != 0
        @obj[:sitting_totals] << [month, month_total]
        @obj[:list_of_months] << "#{year} #{month.to_s.rjust(2, '0')}"
      end

      pointer = year
    end

    return @obj
  end

  def feed
    Sit.where("user_id IN (?)", viewable_and_following_users).with_body.newest_first
  end

  ##
  # PRIVACY
  ##

  def private_journal?
    return true if privacy_setting == 'private'
    return false
  end

  def privacy_setting=(value)
    # If we're moving away from a private journal, need to remove
    # the private marker all sits
    if self.privacy_setting == 'private' && value != 'private'
      sits.unscoped.update_all(private: false)
    # Make my journal private - mark all sits as private
    elsif value == 'private'
      sits.update_all(private: true)
    end
    write_attribute(:privacy_setting, value)
  end

  def viewable_users
    User.select('users.id').where.any_of(
      User.privacy_selected_users(self),
      User.privacy_following_users(self)
    )
  end

  def viewable_and_following_users
    viewable_users | followed_user_ids
  end

  def can_view_content_of(other_user)
    return true if other_user.privacy_setting == 'following' && other_user.following?(self)
    return true if other_user.privacy_setting == 'selected_users' && AuthorisedUser.where(user_id: other_user.id, authorised_user_id: self.id).present?
  end

  # Used to set selected_users on Account Settings form
  def selected_users=(users)
    users.reject! { |c| c.empty? }

    # Clear out old users
    authorised_users.delete_all

    # Add new records
    users.each do |authorised_user|
      AuthorisedUser.create!(user_id: id, authorised_user_id: authorised_user)
    end
  end

  # Used to get selected_users on Account Settings form
  def selected_users
    authorised_users.collect { |u| u.authorised_user_id }
  end

  # All users with public journals
  def self.public_users
    select('users.id').where("users.privacy_setting = 'public'")
  end

  ##
  # RELATIONSHIPS
  ##

  def following?(other_user)
    relationships.find_by_followed_id(other_user.id) ? true : false
  end

  def follow!(other_user)
    follow = relationships.create!(followed_id: other_user.id)
    Notification.send_new_follower_notification(other_user.id, follow)
  end

  def unfollow!(other_user)
    relationships.find_by_followed_id(other_user.id).destroy
  end

  # Is the user following anyone, besides OpenSit?
  def following_anyone?
    follows = followed_user_ids
    follows.delete(97)
    return false if follows.empty?
    return true
  end

  def users_to_follow
    User.joins(:reverse_relationships)
      .where(relationships: { follower_id: followed_user_ids })
      .where.not(relationships: { followed_id: followed_user_ids })
      .where.not(id: self.id)
      .group("users.id")
      .having("COUNT(followed_id) >= ?", 2)
  end

  # Returns ids of users I follow who also follow me
  def mutual_following_ids
    followed_user_ids & follower_ids
  end

  ##
  # NOTIFICATIONS
  ##

  def unread_count
    messages_received.unread.count unless messages_received.unread.count.zero?
  end

  def new_notifications
    notifications.unread.count unless notifications.unread.count.zero?
  end

  ##
  # LIKES
  ##

  def like!(obj)
    Like.create!(likeable_id: obj.id, likeable_type: obj.class.name, user_id: self.id)
  end

  def likes?(obj)
    Like.where(likeable_id: obj.id, likeable_type: obj.class.name, user_id: self.id).present?
  end

  def unlike!(obj)
    like = Like.where(likeable_id: obj.id, likeable_type: obj.class.name, user_id: self.id).first
    like.destroy
  end

  ##
  # STATS
  ##

  def last_update
    self.sits.newest_first.first.created_at
  end

  def streak
    streak_count = 0
    if sits.yesterday.count > 0
      next_newest = false
      sits.newest_first.each do |sit|
        # Only proceed if this isn't the first iteration
        if !next_newest
          next_newest = sit
          next
        end
        # If the 2 consecutive sits weren't on the same day
        if sit.created_at.to_date != next_newest.created_at.to_date
          # Only increment if the distance between the sits is exactly a day
          distance = (next_newest.created_at.to_date - sit.created_at.to_date).to_i
          if distance == 1
            streak_count += 1
          else
            # End of sit streak :(
            break
          end
        end
        next_newest = sit
      end
    end

    # If they sat at least yesterday, or more
    if streak_count > 0
      # And they sat today. Then they get today's sit added to their streak
      if sits.today.count > 0
        streak_count += 1
      else
        # Otherwise a sit streak of 1 doesn't count as a streak :(
        streak_count = 0
      end
    end

    streak_count
  end

  # Overwrite Devise function to allow profile update with password requirement
  # http://stackoverflow.com/questions/4101220/rails-3-devise-how-to-skip-the-current-password-when-editing-a-registratio?rq=1
  def update_with_password(params={})
    if params[:password].blank?
      params.delete(:password)
      params.delete(:password_confirmation) if params[:password_confirmation].blank?
    end
    update_attributes(params)
  end

  def favourited?(sit_id)
    favourites.where(favourable_type: "Sit", favourable_id: sit_id).exists?
  end

  ##
  # CLASS METHODS
  ##

  def self.newest_users(count = 5)
    self.limit(count).newest_first
  end

  def self.active_users
    User.all.where.not(privacy_setting: 'private').order('sits_count DESC')
  end

  ##
  # CALLBACKS
  ##

  after_create :welcome_email, :follow_opensit

  private

    def welcome_email
      UserMailer.welcome_email(self).deliver_now
    end

    def follow_opensit
      relationships.create!(followed_id: 97)
    end

end