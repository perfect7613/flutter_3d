# Image to 3D Model Converter

A Flutter application that converts 2D images into interactive 3D models using Replicate's API.

## Features

- 📸 **Capture images using device camera**
- 🖼️ **Select images from gallery**
- 🔄 **Convert images to 3D models in real-time**
- 🎮 **Interactive 3D model viewer with:**
  - Auto-rotation
  - Camera controls
  - Zoom functionality
  - AR view support

## Prerequisites

- **Flutter SDK** ≥3.6.0
- **Uploadcare API key**
- **Replicate API token**

## Setup

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd flutter_3d
   ```

2. **Create a `.env` file in the project root with your API keys:**
   ```env
   UPLOADCARE_PUBLIC_KEY=your_uploadcare_key
   REPLICATE_API_TOKEN=your_replicate_token
   ```

3. **Install dependencies:**
   ```bash
   flutter pub get
   ```

4. **Run the app:**
   ```bash
   flutter run
   ```

## How It Works

1. The app allows users to select or capture an image.
2. The image is uploaded to **Uploadcare** for hosting.
3. The hosted image URL is sent to **Replicate's API**.
4. **Replicate** processes the image and generates a 3D model.
5. The resulting 3D model is displayed in an interactive viewer.

## Dependencies

- `flutter_dotenv`: For environment variable management
- `http`: For API requests
- `image_picker`: For camera and gallery access
- `uploadcare_client`: For image upload handling
- `model_viewer_plus`: For 3D model visualization

## Project Structure

- **`ModelViewerApp`**: The root application widget.
- **`Image3DModelView`**: The main screen for image selection and 3D model interaction.
