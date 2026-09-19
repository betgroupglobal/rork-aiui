import crypto from 'crypto';
import configLoader from '../config/loader.js';

class PasswordService {
  constructor() {
    this.config = configLoader.getPasswordConfig();
  }

  /**
   * Generate a password based on the configured strategy
   * @returns {string} Generated password
   */
  generatePassword() {
    const strategy = this.config.selection_strategy;
    
    switch (strategy) {
      case 'fixed':
        return this.config.fixed_password;
      case 'pattern':
        return this.generateFromPattern();
      case 'random':
      default:
        return this.generateRandom();
    }
  }

  /**
   * Generate a random password
   * @returns {string} Random password
   */
  generateRandom() {
    const minLength = this.config.min_length || 12;
    const includeNumbers = this.config.include_numbers !== false;
    const includeSymbols = this.config.include_symbols !== false;
    
    let chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    if (includeNumbers) chars += '0123456789';
    if (includeSymbols) chars += '!@#$%^&*()_+-=[]{}|;:,.<>?';
    
    let password = '';
    const randomBytes = crypto.randomBytes(minLength * 2); // Get extra bytes for safety
    
    for (let i = 0; i < minLength; i++) {
      const byte = randomBytes[i];
      password += chars[byte % chars.length];
    }
    
    return password;
  }

  /**
   * Generate password from pattern
   * @returns {string} Password based on pattern
   */
  generateFromPattern() {
    const pattern = this.config.password_pattern || '{random}';
    
    if (pattern === '{random}') {
      return this.generateRandom();
    }
    
    // Simple pattern replacement
    return pattern
      .replace('{random}', this.generateRandom())
      .replace('{timestamp}', Date.now().toString())
      .replace('{uuid}', crypto.randomUUID());
  }

  /**
   * Validate password strength
   * @param {string} password - Password to validate
   * @returns {Object} Validation result
   */
  validatePassword(password) {
    const result = {
      valid: true,
      errors: []
    };
    
    if (password.length < (this.config.min_length || 12)) {
      result.valid = false;
      result.errors.push(`Password must be at least ${this.config.min_length} characters`);
    }
    
    if (this.config.include_numbers && !/\d/.test(password)) {
      result.valid = false;
      result.errors.push('Password must include numbers');
    }
    
    if (this.config.include_symbols && !/[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?]/.test(password)) {
      result.valid = false;
      result.errors.push('Password must include symbols');
    }
    
    return result;
  }
}

export default PasswordService;