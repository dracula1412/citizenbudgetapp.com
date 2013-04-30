# coding: utf-8

class Response
  include Mongoid::Document
  include Mongoid::Paranoia
  include Mongoid::Timestamps

  # Don't embed, as a popular questionnaire may be over 16MB in size.
  belongs_to :questionnaire

  field :initialized_at, type: Time
  field :answers, type: Hash
  field :ip, type: String
  field :assessment, type: Float

  # The social sharing feature requires email and name.
  field :email, type: String
  field :name, type: String

  validates_presence_of :questionnaire_id, :initialized_at, :answers, :ip
  # We don't do more ambitious validation to avoid excluding valid responses.

  # @return [Float] the time to submit the response in seconds
  def time_to_complete
    persisted? && created_at - initialized_at
  end

  # @param [Question] question a question
  # @return the answer to the question
  def answer(question)
    answers[question.id.to_s] || question.default_value
  end

  # @param [Question] question a question
  # @return the answer to the question, cast to an appropriate type
  def cast_answer(question)
    question.cast_value answer(question)
  end

  # @param [Question] question a question
  # @return the difference from the default value
  def difference(question)
    cast_answer(question) - question.cast_default_value
  end

  # @param [Question] question a question
  # @return the financial impact of the answer to the question
  def impact(question)
    difference(question) * question.unit_amount
  end

  def balance
    balance = questionnaire.starting_balance || 0
    questionnaire.sections.each do |section|
      section.questions.each do |question|
        if question.budgetary?
          if questionnaire.mode == 'taxes' || section.group == 'revenue'
            balance += impact question
          elsif section.group == 'expense'
            balance -= impact question
          end
        end
      end
    end
    balance
  end

  # @return [String] the full first name and last name initial
  def display_name
    if name?
      parts = name.strip.split(' ', 2)
      parts[0] = UnicodeUtils.titlecase(parts[0]) if parts[0][/\A\p{Ll}/]
      parts[1] = "#{UnicodeUtils.upcase(parts[1][0])}." if parts[1]
      parts.join ' '
    end
  end

  # Performs validations outside create or update operations.
  #
  # @return [Hash] any validation errors
  # @note Not named #valid? to not override ActiveModel method.
  def validates?
    errors = {}

    # Validate fields.
    if questionnaire.email_required? && email.blank?
      errors[:email] = I18n.t('errors.messages.blank')
    end

    # Validate answers.
    changed = false
    questionnaire.sections.each do |section|
      section.questions.each do |question|
        value = answer question

        # We don't need to cast values here, as both are strings.
        unless changed || section.group == 'other' || value == question.default_value
          changed = true
        end

        if value.blank?
          if question.required?
            errors[question.id.to_s] = I18n.t('errors.messages.blank')
          end
        elsif question.multiple?
          invalid = value.reject do |v|
            question.options.include? v
          end
          unless invalid.empty?
            errors[question.id.to_s] = I18n.t('errors.messages.inclusion')
          end
        elsif question.options?
          unless question.options.include? cast_answer(question)
            errors[question.id.to_s] = I18n.t('errors.messages.inclusion')
          end
        end
      end
    end

    base = []
    if questionnaire.change_required? && !changed
      base << I18n.t('errors.messages.response_must_change_at_least_one_value')
    end
    if questionnaire.balance? && balance < 0
      base << I18n.t('errors.messages.response_must_balance')
    end
    errors[:base] = base unless base.empty?

    errors
  end

  # @see http://broadcastingadam.com/2012/07/advanced_caching_part_1-caching_strategies/
  # @see lib/active_record/integration.rb
  # @see lib/active_support/cache.rb
  def cache_key
    # Scope "responses/new" by questionnaire, and expire the cache when the
    # questionnaire changes.
    parts = [super]
    parts << questionnaire.updated_at.utc.to_s(:number) if questionnaire?
    # We can expire the cache when assets change by uncommenting the following
    # line, but we already expire it on each commit by setting RAILS_APP_VERSION
    # to the current Git revision in a pre-commit hook.
    #
    # parts << CitizenBudget::Application.config.assets.version
    parts.join '-'
  end
end
