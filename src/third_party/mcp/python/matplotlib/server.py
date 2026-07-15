#!/usr/bin/env python3
"""
Matplotlib MCP Server
Optimized for Flutter multi-server architecture and LLM tool-calling accuracy.
"""

import json
import uuid
import base64
import io
import logging
from logging.handlers import RotatingFileHandler
import os
import yaml
from datetime import datetime
from typing import Dict, Any, List, Optional, Union
from flask import Flask, request, jsonify
from flask_cors import CORS
import matplotlib
matplotlib.use('Agg')  # Non-GUI backend for server use
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns
from scipy import stats

# --- Configuration & Setup ---

def load_config():
    config_path = os.path.join(os.path.dirname(__file__), 'config.yaml')
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = yaml.safe_load(f)
        if 'SERVER_HOST' in os.environ: config['server']['host'] = os.environ['SERVER_HOST']
        if 'SERVER_PORT' in os.environ: config['server']['port'] = int(os.environ['SERVER_PORT'])
        return config
    except:
        return {
            "server": {"host": "0.0.0.0", "port": 3001, "debug": False, "threaded": True},
            "logging": {"level": "DEBUG", "file": "./logs/matplotlib_server.log"}
        }

config = load_config()

app = Flask(__name__)
CORS(app)

MCP_VERSION = "2024-11-05"
SERVER_NAME = "matplotlib-mcp-server"
SERVER_VERSION = "1.1.0"

class MatplotlibMCPServer:
    def __init__(self):
        self.active_requests = {}

    def generate_id(self) -> str: return str(uuid.uuid4())

    def start_request(self, request_id: str, operation: str):
        self.active_requests[request_id] = {
            'operation': operation, 'status': 'started', 'progress': 0,
            'start_time': datetime.now()
        }

    def update_progress(self, request_id: str, progress: int, message: str):
        if request_id in self.active_requests:
            self.active_requests[request_id].update({'progress': progress, 'message': message})

    def complete_request(self, request_id: str, success: bool = True):
        if request_id in self.active_requests:
            self.active_requests[request_id]['status'] = 'completed' if success else 'failed'

    def create_success_response(self, request_id: str, result: Dict) -> Dict:
        """Create a standard JSON-RPC success response"""
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    def handle_initialize(self, params: Dict) -> Dict:
        return {
            "protocolVersion": MCP_VERSION,
            "capabilities": {"tools": self.handle_tools_list().get('tools', [])},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}
        }

    def handle_tools_list(self) -> Dict:
        """
        Refined Tool Descriptions: Uses Context-Action-Constraint format.
        Designed to minimize context window bloat while maximizing model steering.
        """
        return {
            "tools": [
                {
                    "name": "matplotlib_create_line_plot",
                    "description": "CONTEXT: Use for trends, time-series, or comparing continuous datasets (e.g., revenue over time). ACTION: Plots multiple datasets with custom line styles and markers. CONSTRAINT: X-data must be numeric or ISO-8601 datetime strings. Required: datasets[[x_data, y_data]].",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "datasets": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "x_data": {"type": "array", "items": {"type": ["number", "string"]}},
                                        "y_data": {"type": "array", "items": {"type": "number"}},
                                        "label": {"type": "string"},
                                        "color": {"type": "string", "default": "auto"},
                                        "line_style": {"type": "string", "enum": ["-", "--", "-.", ":"], "default": "-"}
                                    },
                                    "required": ["x_data", "y_data"]
                                }
                            },
                            "title": {"type": "string"},
                            "xlabel": {"type": "string"},
                            "ylabel": {"type": "string"},
                            "datetime_format": {"type": "string", "description": "e.g., '%Y-%m-%d'"},
                            "figure_size": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2}
                        },
                        "required": ["datasets"]
                    }
                },
                {
                    "name": "matplotlib_create_scatter_plot",
                    "description": "CONTEXT: Use for correlations, clusters, or 3D bubble charts (experience vs salary). ACTION: Encodes 3rd/4th dimensions via point size or color gradient. CONSTRAINT: Single dataset required for trend lines. Required: datasets[[x_data, y_data]].",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "datasets": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "x_data": {"type": "array", "items": {"type": "number"}},
                                        "y_data": {"type": "array", "items": {"type": "number"}},
                                        "size_data": {"type": "array", "items": {"type": "number"}, "description": "Optional: Bubble sizes"},
                                        "color_data": {"type": "array", "items": {"type": "number"}, "description": "Optional: Gradient values"}
                                    },
                                    "required": ["x_data", "y_data"]
                                }
                            },
                            "show_correlation": {"type": "boolean", "default": False}
                        },
                        "required": ["datasets"]
                    }
                },
                {
                    "name": "matplotlib_create_bar_plot",
                    "description": "CONTEXT: Use for comparing categorical data (Sales by Region). ACTION: Renders vertical bars with auto-rotated labels. CONSTRAINT: 5-30 categories recommended for readability.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "categories": {"type": "array", "items": {"type": "string"}},
                            "values": {"type": "array", "items": {"type": "number"}},
                            "title": {"type": "string"},
                            "ylabel": {"type": "string"}
                        },
                        "required": ["categories", "values"]
                    }
                },
                {
                    "name": "matplotlib_statistical_summary",
                    "description": "CONTEXT: Use for deep data validation or research. ACTION: Generates a 4-plot grid: Histogram (Distribution), Box Plot (Quartiles), Q-Q (Normality), and Sequential. CONSTRAINT: Input must be a flat numeric array.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "data": {"type": "array", "items": {"type": "number"}},
                            "title": {"type": "string"}
                        },
                        "required": ["data"]
                    }
                }
            ]
        }

    # --- Tool Call Logic ---
    # Note: Tool implementations remain stable, focusing on progress updates for the Flutter UI.

    def handle_tool_call(self, name: str, arguments: Dict, request_id: str = None) -> Dict:
        if request_id is None: request_id = self.generate_id()
        self.start_request(request_id, name)
        
        try:
            if name == "matplotlib_create_line_plot": return self.create_line_plot(request_id, **arguments)
            elif name == "matplotlib_create_scatter_plot": return self.create_scatter_plot(request_id, **arguments)
            elif name == "matplotlib_create_bar_plot": return self.create_bar_plot(request_id, **arguments)
            elif name == "matplotlib_statistical_summary": return self.create_statistical_summary(request_id, **arguments)
            else: raise ValueError(f"Tool {name} not found")
        except Exception as e:
            self.complete_request(request_id, success=False)
            return {"content": [{"type": "text", "text": f"Error: {str(e)}"}], "isError": True}

    def _plot_to_base64(self) -> str:
        buffer = io.BytesIO()
        plt.savefig(buffer, format='png', dpi=100, bbox_inches='tight')
        buffer.seek(0)
        img = base64.b64encode(buffer.getvalue()).decode('utf-8')
        plt.close()
        return img

    def create_line_plot(self, request_id, datasets, title="Plot", xlabel="X", ylabel="Y", datetime_format="", figure_size=(12, 7)):
        self.update_progress(request_id, 20, "Parsing Datasets...")
        plt.figure(figsize=tuple(figure_size))
        for ds in datasets:
            x, y = ds['x_data'], ds['y_data']
            if isinstance(x[0], str): x = pd.to_datetime(x)
            plt.plot(x, y, label=ds.get('label', ''), color=ds.get('color', None), linestyle=ds.get('line_style', '-'))
        plt.title(title); plt.xlabel(xlabel); plt.ylabel(ylabel); plt.legend(); plt.grid(True)
        self.update_progress(request_id, 80, "Rendering PNG...")
        res = self._plot_to_base64()
        self.complete_request(request_id)
        return {"content": [{"type": "image", "data": res, "mimeType": "image/png"}]}

    def create_scatter_plot(self, request_id, datasets, title="Scatter Plot", xlabel="X", ylabel="Y", show_correlation=False, figure_size=(12, 7)):
        self.update_progress(request_id, 20, "Processing data...")
        plt.figure(figsize=tuple(figure_size))
        for ds in datasets:
            x, y = ds['x_data'], ds['y_data']
            size = ds.get('size_data', None)
            color = ds.get('color_data', None)
            if size and color:
                plt.scatter(x, y, s=size, c=color, alpha=0.6, cmap='viridis')
                plt.colorbar(label='Color Scale')
            elif size:
                plt.scatter(x, y, s=size, alpha=0.6)
            else:
                plt.scatter(x, y, alpha=0.6)
        if show_correlation and len(datasets) == 1:
            x, y = datasets[0]['x_data'], datasets[0]['y_data']
            z = np.polyfit(x, y, 1)
            p = np.poly1d(z)
            plt.plot(x, p(x), "r--", alpha=0.8, label=f'Trend: y={z[0]:.2f}x+{z[1]:.2f}')
            plt.legend()
        plt.title(title); plt.xlabel(xlabel); plt.ylabel(ylabel); plt.grid(True)
        self.update_progress(request_id, 80, "Rendering PNG...")
        res = self._plot_to_base64()
        self.complete_request(request_id)
        return {"content": [{"type": "image", "data": res, "mimeType": "image/png"}]}

    def create_bar_plot(self, request_id, categories, values, title="Bar Chart", ylabel="Value", figure_size=(12, 7)):
        self.update_progress(request_id, 20, "Creating bar plot...")
        plt.figure(figsize=tuple(figure_size))
        plt.bar(categories, values)
        plt.title(title); plt.ylabel(ylabel)
        plt.xticks(rotation=45, ha='right')
        plt.tight_layout()
        self.update_progress(request_id, 80, "Rendering PNG...")
        res = self._plot_to_base64()
        self.complete_request(request_id)
        return {"content": [{"type": "image", "data": res, "mimeType": "image/png"}]}

    def create_statistical_summary(self, request_id, data, title="Statistical Summary"):
        self.update_progress(request_id, 20, "Computing statistics...")
        fig, axes = plt.subplots(2, 2, figsize=(14, 10))
        fig.suptitle(title, fontsize=16)
        
        # Histogram
        axes[0, 0].hist(data, bins=30, edgecolor='black', alpha=0.7)
        axes[0, 0].set_title('Distribution')
        axes[0, 0].set_xlabel('Value')
        axes[0, 0].set_ylabel('Frequency')
        
        # Box Plot
        axes[0, 1].boxplot(data, vert=True)
        axes[0, 1].set_title('Box Plot (Quartiles)')
        axes[0, 1].set_ylabel('Value')
        
        # Q-Q Plot
        stats.probplot(data, dist="norm", plot=axes[1, 0])
        axes[1, 0].set_title('Q-Q Plot (Normality Test)')
        
        # Sequential Plot
        axes[1, 1].plot(data, marker='o', linestyle='-', markersize=4)
        axes[1, 1].set_title('Sequential Plot')
        axes[1, 1].set_xlabel('Index')
        axes[1, 1].set_ylabel('Value')
        axes[1, 1].grid(True)
        
        plt.tight_layout()
        self.update_progress(request_id, 80, "Rendering PNG...")
        buffer = io.BytesIO()
        plt.savefig(buffer, format='png', dpi=100, bbox_inches='tight')
        buffer.seek(0)
        img = base64.b64encode(buffer.getvalue()).decode('utf-8')
        plt.close()
        self.complete_request(request_id)
        return {"content": [{"type": "image", "data": img, "mimeType": "image/png"}]}

# --- App Routes ---

mcp_server = MatplotlibMCPServer()

@app.route('/mcp', methods=['POST'])
def handle_mcp():
    data = request.get_json()
    method = data.get('method')
    request_id = data.get('id', mcp_server.generate_id())
    if method == "initialize": return jsonify(mcp_server.create_success_response(request_id, mcp_server.handle_initialize({})))
    if method == "tools/list": return jsonify(mcp_server.create_success_response(request_id, mcp_server.handle_tools_list()))
    if method == "tools/call":
        res = mcp_server.handle_tool_call(data['params']['name'], data['params'].get('arguments', {}), request_id)
        return jsonify({"jsonrpc": "2.0", "id": request_id, "result": res})
    return jsonify({"error": "Method not allowed"}), 405

@app.route('/health', methods=['GET'])
def health(): return jsonify({"status": "healthy", "server": SERVER_NAME})

@app.route('/tools', methods=['GET'])
def get_tools():
    """GET endpoint to fetch all available tools and their descriptions"""
    tools_data = mcp_server.handle_tools_list()
    return jsonify({
        "server": SERVER_NAME,
        "version": SERVER_VERSION,
        "tools": tools_data['tools'],
        "count": len(tools_data['tools'])
    }), 200

if __name__ == '__main__':
    app.run(host=config['server']['host'], port=config['server']['port'])