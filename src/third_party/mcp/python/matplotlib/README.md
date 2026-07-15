# Enhanced Matplotlib MCP Server 🚀

A professional Model Context Protocol (MCP) server that provides advanced matplotlib plotting capabilities with multi-dataset support, real-time progress tracking, and comprehensive visualization tools. Perfect for data analysis, dashboards, reports, and interactive visualizations.

## ✨ What This Server Can Do

### 📊 Six Professional Plot Types
1. **Line Plots** - Trends, time series, multi-dataset comparisons with datetime support
2. **Scatter Plots** - Correlation analysis, clustering, bubble charts (up to 4D visualization)
3. **Bar Plots** - Categorical comparisons, rankings, forecasts
4. **Histograms** - Distribution analysis, frequency patterns
5. **Statistical Summaries** - Complete 4-panel analysis (histogram, box plot, Q-Q plot, sequential)
6. **IoT Temperature Plots** - Specialized WSAgrar sensor data visualization

### 🎨 Advanced Visualization Features
- **Multi-Dataset Support**: Plot multiple data series on a single chart with individual styling
- **Datetime Axes**: Automatic parsing and custom formatting for time-based data
- **Bubble Charts**: Size and color encoding for multi-dimensional scatter plots
- **Correlation Analysis**: Trend lines and correlation coefficients
- **Custom Styling**: Full control over colors, line styles, markers, transparency, and figure sizes
- **Progress Tracking**: Real-time monitoring with web interface and API endpoints
- **Smart Error Handling**: Detailed error messages with actionable troubleshooting tips

### 🛠️ Production-Ready Infrastructure
- **Docker Support**: Multi-service networking with docker-compose
- **YAML Configuration**: External config with environment variable overrides
- **Rotating Logs**: Organized logging with 5MB files and 5 backups
- **Health Monitoring**: `/health` endpoint for service status
- **Interactive Documentation**: `/help` endpoint with examples and API reference
- **Backward Compatible**: Supports legacy single-dataset format

## 🚀 Quick Start

### Traditional Installation
```bash
# Clone and setup
git clone <repository-url>
cd matplotlib_mcp_server
pip install -r requirements.txt

# Run the server
python server.py
```

### Docker Installation (Recommended)
```bash
# Build and run with Docker
docker build -t matplotlib-mcp .
docker run -p 3950:3950 -v $(pwd)/logs:/app/logs matplotlib-mcp

# Or use docker-compose for multi-service environments
docker-compose up -d
```

The server will start on `http://localhost:3950` by default.

## 🤖 Using with MCP Clients

### Quick Setup

Add to your MCP client configuration (e.g., Claude Desktop):

```json
{
  "mcpServers": {
    "matplotlib": {
      "command": "python",
      "args": ["C:/path/to/server.py"],
      "env": {
        "SERVER_HOST": "0.0.0.0",
        "SERVER_PORT": "3950"
      }
    }
  }
}
```

### Natural Language Examples

The server understands natural language requests:

**Line Plots:**
- "Create a line plot showing temperature trends for the last 12 months"
- "Compare sales for Products A, B, and C with different colors"
- "Show revenue over time from Jan to Dec 2024"

**Scatter Plots:**
- "Make a scatter plot showing correlation between experience and salary"
- "Create a bubble chart with size representing company revenue"
- "Show the relationship between advertising spend and sales with trend line"

**Bar Charts:**
- "Create a bar chart comparing wind speed forecast for the next 6 hours"
- "Show sales by region for Q4"
- "Compare employee counts across departments"

**Histograms:**
- "Show the distribution of test scores"
- "Create a histogram of daily temperatures"

**Statistical Analysis:**
- "Give me a complete statistical analysis of this sensor data"
- "Analyze this dataset and show all statistics"

📖 **See [MCP_CLIENT_GUIDE.md](./MCP_CLIENT_GUIDE.md) for comprehensive usage guide with examples and tips**

## 📊 Usage Examples

### Multi-Dataset Line Plot
```python
payload = {
    "method": "tools/call",
    "params": {
        "name": "matplotlib_create_line_plot",
        "arguments": {
            "datasets": [
                {
                    "x_data": [1, 2, 3, 4, 5],
                    "y_data": [2, 4, 6, 8, 10],
                    "label": "Linear Growth",
                    "color": "#1f77b4",
                    "marker": "o"
                },
                {
                    "x_data": [1, 2, 3, 4, 5], 
                    "y_data": [1, 4, 2, 8, 5],
                    "label": "Volatile Data",
                    "color": "#ff7f0e",
                    "line_style": "--",
                    "marker": "s"
                }
            ],
            "title": "Sales Comparison",
            "xlabel": "Quarter",
            "ylabel": "Revenue ($1000s)",
            "grid": true,
            "legend": true
        }
    }
}

response = requests.post("http://localhost:3950/mcp", json=payload)
```

### Datetime Line Plot
```python
payload = {
    "method": "tools/call",
    "params": {
        "name": "matplotlib_create_line_plot", 
        "arguments": {
            "datasets": [{
                "x_data": ["2023-01-01", "2023-02-01", "2023-03-01"],
                "y_data": [100, 120, 150],
                "label": "Monthly Revenue"
            }],
            "title": "Revenue Trend",
            "datetime_format": "%b %Y"
        }
    }
}
```

### Bubble Chart Scatter Plot
```python
payload = {
    "method": "tools/call",
    "params": {
        "name": "matplotlib_create_scatter_plot",
        "arguments": {
            "datasets": [{
                "x_data": [1, 2, 3, 4, 5],
                "y_data": [2, 4, 1, 6, 3],
                "size_data": [20, 50, 100, 30, 80],
                "color_data": [1, 2, 3, 4, 5],
                "label": "Performance Metrics"
            }],
            "title": "Employee Performance",
            "show_correlation": true
        }
    }
}
```

## 📚 API Reference

### Available Endpoints

- **`POST /mcp`** - Main MCP protocol endpoint for plot generation
- **`GET /health`** - Server health check and status
- **`GET /help`** - Comprehensive documentation and examples
- **`GET /progress/{request_id}`** - Real-time progress monitoring
- **`GET /progress`** - Interactive progress monitoring interface

### Available Tools

#### Enhanced Plotting Tools
- **`matplotlib_create_line_plot`** - Multi-dataset line charts with datetime support
- **`matplotlib_create_scatter_plot`** - Advanced scatter plots and bubble charts
- **`matplotlib_create_bar_plot`** - Bar charts for categorical data
- **`matplotlib_create_histogram`** - Distribution histograms with custom binning
- **`matplotlib_statistical_summary`** - Comprehensive statistical analysis

#### Specialized Tools
- **`matplotlib_wsagrar_temperature_plot`** - WSAgrar temperature visualizations
- **`matplotlib_help`** - Interactive documentation and examples

### Response Format

All plotting tools return:
```json
{
  "result": {
    "content": [
      {
        "type": "text", 
        "text": "Plot created successfully"
      },
      {
        "type": "image",
        "data": "<base64-encoded-image>",
        "mimeType": "image/png"
      }
    ],
    "isError": false
  }
}
```

## Usage with WSAgrar Flutter Client

The matplotlib MCP server integrates seamlessly with your WSAgrar Flutter client's multi-server architecture:

### Example Commands

1. **Temperature Analysis**:
   ```
   "Get temperature data for device 48 and create a line chart"
   ```

2. **Statistical Overview**:
   ```
   "Create a statistical summary for the last 24 hours of measurements"
   ```

3. **Distribution Analysis**: 
   ```
   "Show me a histogram of humidity values from device 67"
   ```

### Data Flow

1. Flutter app gets device data via WSAgrar MCP server (port 3000)
2. Flutter app sends plotting request to matplotlib MCP server (port 3001) 
3. Matplotlib server creates visualization and returns base64 image
4. Flutter app displays both data and chart in collapsible tool output

## 🔧 Configuration

### Configuration Files
- **`config.yaml`** - Development configuration
- **`config.prod.yaml`** - Production-optimized settings

### Key Configuration Options
```yaml
server:
  host: "0.0.0.0"        # Server host (Docker-ready)
  port: 3950             # Server port
  
logging:
  level: "INFO"          # Log level
  file: "./logs/matplotlib_server.log"
  max_bytes: 5242880     # 5MB max file size
  backup_count: 5        # Keep 5 backup files
```

### Environment Variable Overrides
- `MATPLOTLIB_SERVER_HOST` - Override server host
- `MATPLOTLIB_SERVER_PORT` - Override server port  
- `MATPLOTLIB_LOG_LEVEL` - Override log level

## 📈 Progress Monitoring

### Real-Time Progress Tracking
Visit `http://localhost:3950/progress` for a live progress monitoring interface that shows:
- Active plot generation requests
- Completion status and timing
- Error states with detailed messages
- Request queue and processing statistics

### API Progress Monitoring
```bash
# Check specific request progress
curl http://localhost:3950/progress/{request_id}

# Get all active requests
curl http://localhost:3950/progress
```

## 🧪 Testing

Run the comprehensive test suite:
```bash
# Make sure server is running first
python server.py &

# Run enhancement tests  
python test_enhancements.py

# Run original tests
python test_server.py
```

The test suite validates:
- Multi-dataset plotting capabilities
- Datetime axis handling
- Bubble chart functionality
- Error handling and validation
- Progress tracking system
- Documentation endpoints

## 🐳 Docker Deployment

### Single Container
```bash
docker build -t matplotlib-mcp .
docker run -p 3950:3950 -v $(pwd)/logs:/app/logs matplotlib-mcp
```

### Multi-Service with Docker Compose
```yaml
version: '3.8'
services:
  matplotlib-server:
    build: .
    ports:
      - "3950:3950"
    volumes:
      - ./logs:/app/logs
    networks:
      - app-network
    environment:
      - MATPLOTLIB_SERVER_HOST=0.0.0.0

networks:
  app-network:
    driver: bridge
```

## Server Information

The enhanced server runs on:
- **Host**: 0.0.0.0 (Docker-ready)
- **Port**: 3950 (configurable)
- **Protocol**: HTTP MCP
- **Image Format**: PNG (base64 encoded)
- **Features**: Multi-dataset, progress tracking, comprehensive documentation

## Integration Notes

This server is designed to work with the WSAgrar MCP Flutter client's `MultiMCPManager` which routes requests between:
- WSAgrar MCP Server (localhost:3000) - Data retrieval
- Matplotlib MCP Server (localhost:3001) - Data visualization

The LLM automatically determines which server to use based on the request type.