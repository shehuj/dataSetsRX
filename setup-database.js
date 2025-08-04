const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');
require('dotenv').config();

// Database configuration
const dbConfig = {
    host: process.env.DB_HOST || 'localhost',
    port: process.env.DB_PORT || 5432,
    database: process.env.DB_NAME || 'patient_survey_db',
    user: process.env.DB_USER || 'nodejs',
    password: process.env.DB_PASSWORD,
    ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
};

const pool = new Pool(dbConfig);

// SQL Schema definitions
const createTablesSQL = `
-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create surveys table
CREATE TABLE IF NOT EXISTS surveys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id VARCHAR(255) NOT NULL,
    study_id VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    completion_time INTEGER, -- in milliseconds
    status VARCHAR(50) DEFAULT 'in_progress', -- 'in_progress', 'completed', 'abandoned'
    ip_address INET,
    user_agent TEXT,
    session_id VARCHAR(255),
    version INTEGER DEFAULT 1,
    metadata JSONB DEFAULT '{}',
    
    -- Indexes
    CONSTRAINT unique_patient_study UNIQUE(patient_id, study_id, version)
);

-- Create survey_responses table
CREATE TABLE IF NOT EXISTS survey_responses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    survey_id UUID NOT NULL REFERENCES surveys(id) ON DELETE CASCADE,
    question_id INTEGER NOT NULL,
    question_text TEXT NOT NULL,
    question_type VARCHAR(50) NOT NULL, -- 'text', 'number', 'boolean', 'multiple_choice', 'scale', 'checkbox'
    response_value JSONB NOT NULL, -- Stores the actual response data
    response_text TEXT, -- Human-readable version of response
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Constraints
    CONSTRAINT unique_survey_question UNIQUE(survey_id, question_id)
);

-- Create audit log table for tracking changes
CREATE TABLE IF NOT EXISTS survey_audit_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    survey_id UUID REFERENCES surveys(id) ON DELETE CASCADE,
    action VARCHAR(50) NOT NULL, -- 'created', 'updated', 'completed', 'deleted'
    old_values JSONB,
    new_values JSONB,
    changed_by VARCHAR(255),
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create study configurations table
CREATE TABLE IF NOT EXISTS study_configs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    study_id VARCHAR(255) UNIQUE NOT NULL,
    study_name VARCHAR(255) NOT NULL,
    description TEXT,
    questions JSONB NOT NULL, -- Store the survey questions configuration
    settings JSONB DEFAULT '{}', -- Study-specific settings
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(255),
    version INTEGER DEFAULT 1
);

-- Create sessions table for tracking user sessions
CREATE TABLE IF NOT EXISTS survey_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id VARCHAR(255) UNIQUE NOT NULL,
    patient_id VARCHAR(255),
    study_id VARCHAR(255),
    ip_address INET,
    user_agent TEXT,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_activity TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT true,
    data JSONB DEFAULT '{}'
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_surveys_patient_id ON surveys(patient_id);
CREATE INDEX IF NOT EXISTS idx_surveys_study_id ON surveys(study_id);
CREATE INDEX IF NOT EXISTS idx_surveys_created_at ON surveys(created_at);
CREATE INDEX IF NOT EXISTS idx_surveys_status ON surveys(status);
CREATE INDEX IF NOT EXISTS idx_surveys_completed_at ON surveys(completed_at);

CREATE INDEX IF NOT EXISTS idx_survey_responses_survey_id ON survey_responses(survey_id);
CREATE INDEX IF NOT EXISTS idx_survey_responses_question_id ON survey_responses(question_id);
CREATE INDEX IF NOT EXISTS idx_survey_responses_created_at ON survey_responses(created_at);

CREATE INDEX IF NOT EXISTS idx_audit_log_survey_id ON survey_audit_log(survey_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON survey_audit_log(action);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON survey_audit_log(created_at);

CREATE INDEX IF NOT EXISTS idx_study_configs_study_id ON study_configs(study_id);
CREATE INDEX IF NOT EXISTS idx_study_configs_is_active ON study_configs(is_active);

CREATE INDEX IF NOT EXISTS idx_sessions_session_id ON survey_sessions(session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_patient_id ON survey_sessions(patient_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON survey_sessions(expires_at);
CREATE INDEX IF NOT EXISTS idx_sessions_is_active ON survey_sessions(is_active);

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create triggers for updated_at columns
DROP TRIGGER IF EXISTS update_surveys_updated_at ON surveys;
CREATE TRIGGER update_surveys_updated_at
    BEFORE UPDATE ON surveys
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_survey_responses_updated_at ON survey_responses;
CREATE TRIGGER update_survey_responses_updated_at
    BEFORE UPDATE ON survey_responses
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_study_configs_updated_at ON study_configs;
CREATE TRIGGER update_study_configs_updated_at
    BEFORE UPDATE ON study_configs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Create function to clean up expired sessions
CREATE OR REPLACE FUNCTION cleanup_expired_sessions()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM survey_sessions 
    WHERE expires_at < CURRENT_TIMESTAMP 
    OR (is_active = false AND last_activity < CURRENT_TIMESTAMP - INTERVAL '7 days');
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Create function to get survey statistics
CREATE OR REPLACE FUNCTION get_survey_stats(study_id_param VARCHAR DEFAULT NULL)
RETURNS TABLE(
    total_surveys BIGINT,
    completed_surveys BIGINT,
    in_progress_surveys BIGINT,
    abandoned_surveys BIGINT,
    avg_completion_time NUMERIC,
    completion_rate NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(*) as total_surveys,
        COUNT(*) FILTER (WHERE status = 'completed') as completed_surveys,
        COUNT(*) FILTER (WHERE status = 'in_progress') as in_progress_surveys,
        COUNT(*) FILTER (WHERE status = 'abandoned') as abandoned_surveys,
        AVG(completion_time)::NUMERIC as avg_completion_time,
        CASE 
            WHEN COUNT(*) > 0 THEN 
                (COUNT(*) FILTER (WHERE status = 'completed')::NUMERIC / COUNT(*)::NUMERIC * 100)
            ELSE 0 
        END as completion_rate
    FROM surveys 
    WHERE (study_id_param IS NULL OR study_id = study_id_param);
END;
$$ LANGUAGE plpgsql;
`;

// Insert sample study configuration
const insertSampleStudySQL = `
INSERT INTO study_configs (study_id, study_name, description, questions, settings, created_by)
VALUES (
    'DEMO_STUDY_001',
    'Demo Patient Survey Study',
    'A comprehensive patient survey for drug development research',
    $1,
    $2,
    'system'
) ON CONFLICT (study_id) DO NOTHING;
`;

// Sample questions configuration
const sampleQuestions = [
    {
        id: 1,
        question: "What is your age?",
        type: "number",
        required: true,
        min: 18,
        max: 120
    },
    {
        id: 2,
        question: "What is your biological sex?",
        type: "multiple_choice",
        options: ["Male", "Female", "Other", "Prefer not to say"],
        required: true
    },
    {
        id: 3,
        question: "How would you rate your overall health?",
        type: "scale",
        scale: { min: 1, max: 5, labels: ["Poor", "Fair", "Good", "Very Good", "Excellent"] },
        required: true
    },
    {
        id: 4,
        question: "Do you currently take any prescription medications?",
        type: "boolean",
        required: true
    },
    {
        id: 5,
        question: "If yes, please list your current medications:",
        type: "text",
        required: false,
        dependsOn: { questionId: 4, value: true }
    }
];

// Sample settings
const sampleSettings = {
    maxCompletionTime: 3600000, // 1 hour in milliseconds
    allowMultipleSubmissions: false,
    requireAllQuestions: true,
    saveProgress: true,
    sessionTimeout: 1800000, // 30 minutes
    rateLimiting: {
        windowMs: 900000, // 15 minutes
        max: 100
    }
};

// Database initialization function
async function initializeDatabase() {
    const client = await pool.connect();
    
    try {
        console.log('🔧 Starting database initialization...');
        
        // Check if database connection works
        const result = await client.query('SELECT NOW()');
        console.log('✅ Database connection successful:', result.rows[0].now);
        
        // Create tables and functions
        console.log('📋 Creating tables and functions...');
        await client.query(createTablesSQL);
        console.log('✅ Tables and functions created successfully');
        
        // Insert sample study configuration
        console.log('📝 Inserting sample study configuration...');
        await client.query(insertSampleStudySQL, [
            JSON.stringify(sampleQuestions),
            JSON.stringify(sampleSettings)
        ]);
        console.log('✅ Sample study configuration inserted');
        
        // Verify table creation
        const tables = await client.query(`
            SELECT table_name 
            FROM information_schema.tables 
            WHERE table_schema = 'public' 
            AND table_type = 'BASE TABLE'
            ORDER BY table_name;
        `);
        
        console.log('📊 Created tables:');
        tables.rows.forEach(row => {
            console.log(`  - ${row.table_name}`);
        });
        
        // Get some basic statistics
        const stats = await client.query('SELECT get_survey_stats()');
        console.log('📈 Initial statistics:', stats.rows[0]);
        
        console.log('🎉 Database initialization completed successfully!');
        
    } catch (error) {
        console.error('❌ Database initialization failed:', error);
        throw error;
    } finally {
        client.release();
    }
}

// Test database functions
async function testDatabase() {
    const client = await pool.connect();
    
    try {
        console.log('🧪 Running database tests...');
        
        // Test survey creation
        const surveyResult = await client.query(`
            INSERT INTO surveys (patient_id, study_id, ip_address, user_agent)
            VALUES ('TEST_PATIENT_001', 'DEMO_STUDY_001', '127.0.0.1', 'Test User Agent')
            RETURNING id, created_at;
        `);
        
        const surveyId = surveyResult.rows[0].id;
        console.log('✅ Test survey created:', surveyId);
        
        // Test response creation
        await client.query(`
            INSERT INTO survey_responses (survey_id, question_id, question_text, question_type, response_value, response_text)
            VALUES ($1, 1, 'What is your age?', 'number', '25', '25');
        `, [surveyId]);
        
        console.log('✅ Test response created');
        
        // Test audit log
        await client.query(`
            INSERT INTO survey_audit_log (survey_id, action, new_values, changed_by, ip_address)
            VALUES ($1, 'created', '{"status": "in_progress"}', 'test_user', '127.0.0.1');
        `, [surveyId]);
        
        console.log('✅ Test audit log created');
        
        // Clean up test data
        await client.query('DELETE FROM surveys WHERE patient_id = $1', ['TEST_PATIENT_001']);
        console.log('✅ Test data cleaned up');
        
        console.log('🎉 Database tests passed!');
        
    } catch (error) {
        console.error('❌ Database tests failed:', error);
        throw error;
    } finally {
        client.release();
    }
}

// Main execution
async function main() {
    try {
        await initializeDatabase();
        
        if (process.env.NODE_ENV !== 'production') {
            await testDatabase();
        }
        
        console.log('\n🚀 Ready to start the application!');
        console.log('📍 Database:', dbConfig.database);
        console.log('🏠 Host:', dbConfig.host);
        console.log('🔌 Port:', dbConfig.port);
        
    } catch (error) {
        console.error('💥 Setup failed:', error.message);
        process.exit(1);
    } finally {
        await pool.end();
    }
}

// Handle graceful shutdown
process.on('SIGINT', async () => {
    console.log('\n🛑 Received SIGINT, closing database connection...');
    await pool.end();
    process.exit(0);
});

process.on('SIGTERM', async () => {
    console.log('\n🛑 Received SIGTERM, closing database connection...');
    await pool.end();
    process.exit(0);
});

// Export for use in other modules
module.exports = {
    pool,
    initializeDatabase,
    testDatabase
};

// Run if called directly
if (require.main === module) {
    main();
}
// setup-database.js
const sqlite3 = require('sqlite3').verbose();

const db = new sqlite3.Database('./patient_data.db');

db.serialize(() => {
  // Create surveys table
  db.run(`
    CREATE TABLE IF NOT EXISTS surveys (
      survey_id TEXT PRIMARY KEY,
      patient_id TEXT NOT NULL,
      study_id TEXT NOT NULL,
      completed_at TEXT NOT NULL,
      metadata TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      INDEX(study_id),
      INDEX(patient_id)
    )
  `);

  // Create responses table
  db.run(`
    CREATE TABLE IF NOT EXISTS responses (
      response_id TEXT PRIMARY KEY,
      survey_id TEXT NOT NULL,
      question_id INTEGER NOT NULL,
      question_text TEXT NOT NULL,
      answer TEXT NOT NULL,
      response_type TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(survey_id) REFERENCES surveys(survey_id),
      INDEX(survey_id)
    )
  `);

  console.log('Database tables created successfully');
});

db.close();


