import math
from pathlib import Path

import pandas as pd

PATH = Path(__file__).resolve().parent.parent.parent / "data" / "for_graphics.csv"

x_min = -10
x_max = 5

def generate():
    x_list = [i * 10 / (x_max - 1) for i in range(x_min, x_max)]
    y_sin = [math.sin(x) for x in x_list]
    y_cos = [math.cos(x) for x in x_list]
    points = list(zip(x_list, y_sin, y_cos))
    print("Generate %s point" % len(points))
    return points

def safe_file(points: list[tuple[float, float, float]]):
    df = pd.DataFrame(points, columns=["x", "y_sin", "y_cos"])
    df.to_csv(PATH, index=False)

if __name__ == "__main__":
    points = generate()
    safe_file(points)




