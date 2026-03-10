// Frontend Configuration
// Static config for the Cangjie-only build
window.APP_CONFIG = {
    API_BASE_URL: 'http://localhost:8000',
    APP_NAME: 'AI Doc Read Studio',
    VERSION: '1.0.0',
    frontend: {
        log_level: 'info',
        log_file: 'logs/frontend.log'
    },
    models: {
        available: [
        {
                "value": "gpt-4o-mini",
                "label": "GPT-4o Mini (Fast)",
                "description": "Fastest, Most Cost-Effective",
                "model_id": "gpt-4o-mini"
        },
        {
                "value": "gpt-4o",
                "label": "GPT-4o (Balanced)",
                "description": "Balanced Performance & Cost",
                "model_id": "gpt-4o"
        },
        {
                "value": "gpt-4-turbo",
                "label": "GPT-4 Turbo (Advanced)",
                "description": "Advanced Reasoning",
                "model_id": "gpt-4-turbo"
        }
],
        default_team: 'gpt-4o-mini',
        default_summary: 'gpt-4o'
    }
};