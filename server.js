const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const { v4: uuidv4 } = require('uuid');
const Joi = require('joi');
const path = require('path');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3000;

// Security middleware
app.use(helmet());
app.use(cors({
  origin: process.env.ALLOWED_ORIGINS?.split(',') || ['http://localhost:3000'],
  credentials: true
}));

// Rate limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100 // limit each IP to 100 requests per windowMs
});
app.use(limiter);

app.use(express.json({ limit: '10mb' }));
app.use(express.static('public'));

// Database connection
const db = new sqlite3.Database('./patient_data.db', (err) => {
  if (err) {
    console.error('Error opening database:', err.message);
  } else {
    console.log('Connected to SQLite database');
  }
});

// Survey questions schema
const surveySchema = Joi.object({
  patientId: Joi.string().required(),
  studyId: Joi.string().required(),
  responses: Joi.array().items(
    Joi.object({
      questionId: Joi.number().integer().min(1).max(20).required(),
      question: Joi.string().required(),
      answer: Joi.alternatives().try(
        Joi.string(),
        Joi.number(),
        Joi.boolean(),
        Joi.array()
      ).required(),
      responseType: Joi.string().valid('text', 'number', 'boolean', 'scale', 'multiple_choice').required()
    })
  ).length(20).required(),
  metadata: Joi.object({
    completedAt: Joi.date().iso(),
    deviceInfo: Joi.string(),
    location: Joi.string()
  }).optional()
});

// API Routes

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

// Submit patient survey
app.post('/api/surveys', async (req, res) => {
  try {
    const { error, value } = surveySchema.validate(req.body);
    if (error) {
      return res.status(400).json({ 
        error: 'Validation failed', 
        details: error.details 
      });
    }

    const surveyId = uuidv4();
    const { patientId, studyId, responses, metadata } = value;

    // Insert survey record
    const surveyQuery = `
      INSERT INTO surveys (survey_id, patient_id, study_id, completed_at, metadata)
      VALUES (?, ?, ?, ?, ?)
    `;
    
    db.run(surveyQuery, [
      surveyId,
      patientId,
      studyId,
      metadata?.completedAt || new Date().toISOString(),
      JSON.stringify(metadata || {})
    ], function(err) {
      if (err) {
        console.error('Error inserting survey:', err);
        return res.status(500).json({ error: 'Database error' });
      }

      // Insert responses
      const responseQuery = `
        INSERT INTO responses (response_id, survey_id, question_id, question_text, answer, response_type)
        VALUES (?, ?, ?, ?, ?, ?)
      `;

      let completed = 0;
      let hasError = false;

      responses.forEach((response) => {
        const responseId = uuidv4();
        db.run(responseQuery, [
          responseId,
          surveyId,
          response.questionId,
          response.question,
          JSON.stringify(response.answer),
          response.responseType
        ], (err) => {
          if (err && !hasError) {
            hasError = true;
            console.error('Error inserting response:', err);
            return res.status(500).json({ error: 'Database error' });
          }
          
          completed++;
          if (completed === responses.length && !hasError) {
            res.json({ 
              success: true, 
              surveyId,
              message: 'Survey submitted successfully' 
            });
          }
        });
      });
    });

  } catch (error) {
    console.error('Server error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Get surveys by study
app.get('/api/studies/:studyId/surveys', (req, res) => {
  const { studyId } = req.params;
  const { page = 1, limit = 50 } = req.query;
  const offset = (page - 1) * limit;

  const query = `
    SELECT s.*, COUNT(r.response_id) as response_count
    FROM surveys s
    LEFT JOIN responses r ON s.survey_id = r.survey_id
    WHERE s.study_id = ?
    GROUP BY s.survey_id
    ORDER BY s.completed_at DESC
    LIMIT ? OFFSET ?
  `;

  db.all(query, [studyId, parseInt(limit), offset], (err, rows) => {
    if (err) {
      console.error('Error fetching surveys:', err);
      return res.status(500).json({ error: 'Database error' });
    }

    res.json({
      surveys: rows.map(row => ({
        ...row,
        metadata: JSON.parse(row.metadata || '{}')
      })),
      pagination: {
        page: parseInt(page),
        limit: parseInt(limit),
        hasMore: rows.length === parseInt(limit)
      }
    });
  });
});

// Get detailed survey data
app.get('/api/surveys/:surveyId', (req, res) => {
  const { surveyId } = req.params;

  const surveyQuery = `SELECT * FROM surveys WHERE survey_id = ?`;
  const responsesQuery = `SELECT * FROM responses WHERE survey_id = ? ORDER BY question_id`;

  db.get(surveyQuery, [surveyId], (err, survey) => {
    if (err) {
      console.error('Error fetching survey:', err);
      return res.status(500).json({ error: 'Database error' });
    }

    if (!survey) {
      return res.status(404).json({ error: 'Survey not found' });
    }

    db.all(responsesQuery, [surveyId], (err, responses) => {
      if (err) {
        console.error('Error fetching responses:', err);
        return res.status(500).json({ error: 'Database error' });
      }

      res.json({
        survey: {
          ...survey,
          metadata: JSON.parse(survey.metadata || '{}')
        },
        responses: responses.map(r => ({
          ...r,
          answer: JSON.parse(r.answer)
        }))
      });
    });
  });
});

// Export data for analysis
app.get('/api/studies/:studyId/export', (req, res) => {
  const { studyId } = req.params;
  const { format = 'json' } = req.query;

  const query = `
    SELECT 
      s.survey_id,
      s.patient_id,
      s.study_id,
      s.completed_at,
      s.metadata,
      r.question_id,
      r.question_text,
      r.answer,
      r.response_type
    FROM surveys s
    LEFT JOIN responses r ON s.survey_id = r.survey_id
    WHERE s.study_id = ?
    ORDER BY s.completed_at DESC, r.question_id ASC
  `;

  db.all(query, [studyId], (err, rows) => {
    if (err) {
      console.error('Error exporting data:', err);
      return res.status(500).json({ error: 'Database error' });
    }

    if (format === 'csv') {
      // Convert to CSV format
      const headers = [
        'survey_id', 'patient_id', 'study_id', 'completed_at',
        'question_id', 'question_text', 'answer', 'response_type'
      ];
      
      let csv = headers.join(',') + '\n';
      rows.forEach(row => {
        const values = headers.map(header => {
          let value = row[header];
          if (header === 'answer') {
            value = JSON.parse(value);
            if (typeof value === 'object') {
              value = JSON.stringify(value);
            }
          }
          return `"${String(value).replace(/"/g, '""')}"`;
        });
        csv += values.join(',') + '\n';
      });

      res.setHeader('Content-Type', 'text/csv');
      res.setHeader('Content-Disposition', `attachment; filename="study_${studyId}_data.csv"`);
      res.send(csv);
    } else {
      res.json({ data: rows });
    }
  });
});

// Analytics endpoint
app.get('/api/studies/:studyId/analytics', (req, res) => {
  const { studyId } = req.params;

  const analyticsQuery = `
    SELECT 
      COUNT(DISTINCT s.survey_id) as total_surveys,
      COUNT(DISTINCT s.patient_id) as unique_patients,
      AVG(response_counts.count) as avg_responses_per_survey,
      MIN(s.completed_at) as first_survey,
      MAX(s.completed_at) as last_survey
    FROM surveys s
    LEFT JOIN (
      SELECT survey_id, COUNT(*) as count 
      FROM responses 
      GROUP BY survey_id
    ) response_counts ON s.survey_id = response_counts.survey_id
    WHERE s.study_id = ?
  `;

  db.get(analyticsQuery, [studyId], (err, analytics) => {
    if (err) {
      console.error('Error fetching analytics:', err);
      return res.status(500).json({ error: 'Database error' });
    }

    res.json(analytics || {});
  });
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Patient Data Collection Server running on port ${PORT}`);
});

// Graceful shutdown
process.on('SIGINT', () => {
  console.log('Shutting down server...');
  db.close((err) => {
    if (err) {
      console.error('Error closing database:', err.message);
    }
    console.log('Database connection closed.');
    process.exit(0);
  });
});