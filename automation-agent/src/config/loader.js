import fs from 'fs';
import path from 'path';
import Ajv from 'ajv';
import dotenv from 'dotenv';

// Load environment variables
dotenv.config();

class ConfigLoader {
  constructor(configPath = null) {
    this._configPathOverride = configPath;
    this.schemaPath = './config/config.schema.json';
    this.config = null;
  }

  /**
   * Resolve the config path lazily so CONFIG_PATH set after import time
   * (e.g. by the UI server at startup) is still honoured.
   */
  get configPath() {
    return this._configPathOverride || process.env.CONFIG_PATH || './config/config.json';
  }

  load() {
    try {
      // Load schema
      const schema = JSON.parse(fs.readFileSync(this.schemaPath, 'utf8'));
      
      // Load config
      const configData = JSON.parse(fs.readFileSync(this.configPath, 'utf8'));
      
      // Validate against schema
      const ajv = new Ajv({ allErrors: true });
      const validate = ajv.compile(schema);
      
      if (!validate(configData)) {
        throw new Error(`Config validation failed: ${JSON.stringify(validate.errors, null, 2)}`);
      }
      
      this.config = configData;
      console.log('Configuration loaded successfully');
      return this.config;
    } catch (error) {
      if (error.code === 'ENOENT') {
        throw new Error(`Config file not found at ${this.configPath}. Please copy config.example.json to config.json and fill in your credentials.`);
      }
      throw error;
    }
  }

  get(section) {
    if (!this.config) {
      this.load();
    }
    return section ? this.config[section] : this.config;
  }

  getEmailAliasConfig() {
    return this.get('emailalias');
  }

  getPasswordConfig() {
    return this.get('passwords');
  }

  getReceivingEmailConfig() {
    return this.get('receiving_email');
  }

  getSMSProviderConfig() {
    return this.get('sms_provider');
  }

  getAutomationConfig() {
    return this.get('automation');
  }
}

export default new ConfigLoader();