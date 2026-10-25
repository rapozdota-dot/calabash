/// Canonical, user-facing explanations of the existing model outputs.
class PredictionExplanations {
  PredictionExplanations._();

  static const confidence =
      "This is the detection model's score for the predicted maturity class of this fruit region. It describes how strongly the model supports the prediction. It does not represent measured accuracy, a calibrated probability, or a statistical margin of error.";
  static const segmentation =
      'The highlighted areas show the fruit regions identified by the detection model. These outlines are predictions and may not perfectly match the actual fruit boundaries.';
  static const liveExternalAssessment =
      'Maturity predictions are based on external appearance only.';
}
